#!/bin/bash

set -e # exit immediately if a simple command exits with a non-zero status
set -u # report the usage of uninitialized variables

########################################
# Colors                               #
########################################
function red() {
  echo "\\e[0;31m${*}\\e[0m"
}

function yellow() {
  echo "\\e[0;33m${*}\\e[0m"
}

function green() {
  echo "\\e[0;32m${*}\\e[0m"
}

function cyan() {
  echo "\\e[0;36m${*}\\e[0m"
}


export BOSH_NAME
export backup_guid
export service_plan
export array_app_names
export array_service_key_names
export BROKER_SCRIPT="products/product-cf-hcp/components/service-fabrik/scripts/broker"

function bosh_login() {
    DEP_NAME="$1"
    echo -e "$(cyan "########## Logging into BOSH ##########")"
    if BOSH_NAME="$("$BROKER_SCRIPT" get-director "${DEP_NAME:?}" | jq -r '.name')"; then
        echo "Bosh name: $BOSH_NAME"
        iac -d "$BOSH_NAME" action login
    else
        echo "Bosh name not found"
        exit 1
    fi
}

function cf_login() {

  cf_org="$1"
  cf_space="$2"
  source "products/product-cf-hcp/components/service-fabrik/scripts/common"
  login_cf

  echo -e "$(cyan Targetting to org "$cf_org" and space "$cf_space")"

  if ! cf target -o "${cf_org}" -s "${cf_space}" &>/dev/null ;then
      echo -e "$(red You provided org: "$cf_org" space: "$cf_space" . Please provide valid org and space name )"
      exit 1
  fi
}

function wait_for_backups_to_complete() {
    elapsed=0

    IS_SERVICE_EXISTS="$(cf curl "/v2/service_instances?q=name%3A$service_name" | jq '.total_results')"
    if [ "$IS_SERVICE_EXISTS" ==  "0" ]; then
        echo "Service $service_name not found"
        exit 1
    fi

    backup_state_response="$("$BROKER_SCRIPT" backup-state "$service_name" online)"
    state_response="$(echo "$backup_state_response" | jq -r '.state')"

    while [ "$state_response" = "processing" ]; do
      echo "Backup for $service_name in progress... [Elapsed ${elapsed} sec]"
      elapsed=$((elapsed+60))
      sleep 60
      if (( "$elapsed" % 120 == 0 ))
      then
        cf_login "$cf_org_name" "$cf_space_name"
      fi
      backup_state_response="$("$BROKER_SCRIPT" backup-state "$service_name" online)"
      state_response=$(echo "$backup_state_response" | jq -r '.state')
      if [ "$elapsed" -gt 900 ] ; then
          break
      fi
    done

    if [[ "$(echo "$backup_state_response" | jq -r '.state')" != "succeeded" ]]; then
       echo "Service instance backup failed"
       exit 1
    else
       echo -e "$(green Service instance backup succeeded)"
    fi

    sleep 5
}

function wait_for_service_ops_to_complete() {

    operation="$1"
    s_name="$2"
    elapsed=0

    IS_SERVICE_EXISTS="$(cf curl "/v2/service_instances?q=name%3A$s_name" | jq '.total_results')"
    if [ "$IS_SERVICE_EXISTS" ==  "0" ]; then
        echo "Service $s_name not found"
        exit 1
    fi
    response="$(cf curl "/v2/service_instances?q=name%3A$s_name" | jq '.resources[0].entity.last_operation.state' | awk -F"\"" '{print $2}')"
    echo "After getting the response $response"

    if [ "$response" == 'failed' ] ; then
      operation_status="$("$BROKER_SCRIPT" info "$s_name" | jq -r '.last_operation_state')"
      echo "ERROR : $operation_status"
      exit 1
    fi

    if [ -n "$response" ]; then
        while [ "$response" = 'in progress' ]; do
            echo "$operation is in progress... [Elapsed ${elapsed} sec]"
            sleep 60
            elapsed=$((elapsed+60))
            if (( "$elapsed" % 120 == 0 ))           # no need for brackets
            then
              cf_login "$cf_org_name" "$cf_space_name"
            fi
            response="$(cf curl "/v2/service_instances?q=name%3A$s_name" | jq '.resources[0].entity.last_operation.state' | awk -F"\"" '{print $2}')"
            if [ "$elapsed" -gt 2400 ] ; then
              echo "ERROR : $operation Timeout, Running more than 2400 Secs "
              break
            fi
        done
    fi

    status="$(cf curl "/v2/service_instances?q=name%3A$s_name" | jq '.resources[0].entity.last_operation.state' | awk -F"\"" '{print $2}')"
    if [ "$status" = 'succeeded' ] ; then
      echo "$operation completed."
    elif [ "$status" = 'failed' ] ; then
      operation_status="$("$BROKER_SCRIPT" info "$s_name" | jq -r '.last_operation_state')"
      echo "ERROR : $operation_status"
    fi

    sleep 5
}

function take_backup() {

  echo -e "$(cyan  Start Backup )"

  wait_for_service_ops_to_complete "Operation" "$service_name"

  backup_response="$("$BROKER_SCRIPT" backup-start "$service_name" online)"
  if ! echo "$backup_response" | grep -F "\"status\": 501" &> /dev/null; then
      backup_guid="$(echo "$backup_response" | jq -r '.guid' )"
      if [ ! -z "$backup_guid" ]; then
          echo "Backup started:"
          echo "$backup_response"
      else
          echo "Backup failed"
          echo "$backup_response"
          exit 1
      fi
  else
      echo -e "$(red Service does not support backup.)"
      exit 1
  fi

  wait_for_backups_to_complete "$service_name"

  "$BROKER_SCRIPT" backup-state "$service_name"
}

function find_plan() {
  echo -e "$(cyan Finding the plan of current service instance )"

  service_plan_url="$(cf curl /v2/service_instances?q=name:"$service_name" | jq '.resources[0].entity.service_plan_url' | awk -F"\"" '{print $2}')"
  service_plan="$(cf curl "$service_plan_url" | jq '.entity.name' | awk -F"\"" '{print $2}')"
  echo -e "$(cyan Service plan is "$service_plan")"
}

# Create service instance
function create_service_instance() {

    dummy_service_name="$service_name-dummy"
    echo -e "$(cyan Creating service instances "$dummy_service_name")"

    if ! cf create-service postgresql "${service_plan}" "${dummy_service_name}" &>/dev/null ;then
      echo -e "$(red Failed to create service instance "$dummy_service_name".)"
      exit 1
    fi

    wait_for_service_ops_to_complete "Create" "$dummy_service_name"

    # Get the service guid and deployment name
    IS_SERVICE_EXISTS="$(cf curl "/v2/service_instances?q=name%3A$dummy_service_name" | jq '.total_results')"
    if [ "$IS_SERVICE_EXISTS" !=  "0" ]; then
      SERVICE_GUID="$(cf curl "/v2/service_instances?q=name%3A$dummy_service_name" | jq '.resources[0].metadata.guid' | jq 'select (.!=null)' | awk -F"\"" '{print $2}')"
      if [ -n "$SERVICE_GUID" ]; then
            if DEPLOYMENT_NAME="$("$BROKER_SCRIPT" info "$dummy_service_name" | jq -r '.details.deployment_name')"; then
                echo "Created Service instance"
                echo "Service name: $dummy_service_name"
                echo "Service guid: $SERVICE_GUID"
                echo "Deployment name: $DEPLOYMENT_NAME"
            else
                echo -e "$(red Deployment name not found)"
                cf service "$dummy_service_name"
                exit 1
            fi
      else
          echo "Service guid not found"
      fi
    else
        echo -e "$(red "$dummy_service_name" Service creation failed)"
        exit 1
    fi

    create_State="$(cf curl "/v2/service_instances?q=name%3A$dummy_service_name" | jq '.resources[0].entity.last_operation.state' | awk -F"\"" '{print $2}')"
    if [ "$create_State" = 'succeeded' ] ; then
        echo -e "$(green Service instance creation succeeded)"
        cf service "$dummy_service_name"

        sec_grp="$(cf curl "/v2/security_groups?q=name%3Aservice-fabrik-$SERVICE_GUID")"
        if [ "$(echo "$sec_grp" | jq -r '.total_results')" == "1" ]; then
            echo "Security group creation succeeded"
            echo "$sec_grp" | jq -r '.resources[0].entity.rules'
        else
            echo -e "$(red Security group creation failed!)"
            exit 1
        fi
    else
        echo -e "$(red Service instance creation failed)"
        cf service "$dummy_service_name"
        exit 1
    fi
}
# Find keys associated with service instance
function find_service_keys() {
  echo -e "$(cyan Finding service keys associated with service instance)"
  service_keys_url="$(cf curl "/v2/service_instances?q=name:$service_name" | jq '.resources[0].entity.service_keys_url' | awk -F"\"" '{print $2}')"

  no_of_keys="$(cf curl "$service_keys_url" | jq '.total_results')"
  if [ "$no_of_keys" -eq 0 ]; then
      echo -e "$(cyan No keys found)"
  else
    counter=0
    while [ "$counter" -lt "$no_of_keys" ]; do
      key_name="$(cf curl "$service_keys_url" | jq .resources[$counter].entity.name | awk -F"\"" '{print $2}')"
      array_service_key_names[$counter]="$key_name"
      counter=$((counter+1))
    done
  fi
}

# Unbind the app from service instance
function unbind_app() {

    wait_for_service_ops_to_complete "Operation" "$service_name"

    service_bindings_url="$(cf curl "/v2/service_instances?q=name:$service_name" | jq '.resources[0].entity.service_bindings_url' | awk -F"\"" '{print $2}')"
    no_of_app="$(cf curl "$service_bindings_url" | jq '.total_results')"
    if [ "$no_of_app" -eq 0 ]; then
        echo -e "$(cyan No apps binded ! )"
    else
        counter=0
        while [ "$counter" -lt "$no_of_app" ]; do
          app_guid="$(cf curl "$service_bindings_url" | jq .resources[$counter].entity.app_guid | awk -F"\"" '{print $2}')"
          appName="$(cf curl "/v2/apps/$app_guid" | jq '.entity.name' | awk -F"\"" '{print $2}')"

          array_app_names[$counter]="$appName"

          #Stop the app
          cf stop "$appName"

          #unbind the aoo from service instance
          cf unbind-service "$appName" "$service_name"

          counter=$((counter+1))
        done
    fi

}

function restore_backup() {

  # Run restores afterwards
  echo -e "$(cyan Running restore on new instance ....)"

  IS_SERVICE_EXISTS="$(cf curl "/v2/service_instances?q=name%3A$service_name-dummy" | jq '.total_results')"
  if [ "$IS_SERVICE_EXISTS" ==  "0" ]; then
    echo -e "$(red Service $service_name-dummy does not exist. Exiting..)"
    exit 0
  fi

  restore_response=$("$BROKER_SCRIPT" restore-start "$service_name-dummy" "$backup_guid")
  if ! echo "$restore_response" | grep -F "Got HTTP Status Code 502" &> /dev/null; then
      restore_guid="$(echo "$restore_response" | jq -r '.guid' )"
      if [ ! -z "$restore_guid" ]; then
          echo -e "$(green Restore started)"
          echo "$restore_response"
      else
          echo -e "$(red Restore failed)"
          echo "$restore_response"
          exit 1
      fi
  else
      echo -e "$(red Service does not support restore.)"
      exit 1
  fi

  wait_for_service_ops_to_complete "Restore" "$service_name-dummy"

}

#create service keys on new instance
function create_service_keys() {
  if [ ! -z ${array_service_key_names:-} ]; then
    echo -e "$(cyan Creating service keys for "$service_name" )"
    for item in ${array_service_key_names[*]}
    do
      cf csk "$service_name" "$item"
    done
  else
    echo -e "$(cyan No service keys found !!)"
  fi
}

function bind_apps_to_new_instance() {
  echo -e "$(cyan Binding apps to "$service_name" )"
  if [ ! -z ${array_app_names:-} ]; then
    for item in ${array_app_names[*]}
    do
      cf bind-service "$item" "$service_name"

      cf restage "$item"
    done
  else
    echo -e "$(cyan No apps to bind !!)"
  fi
}

function migrate_instance() {

  echo -e "$(cyan Migrating "$service_name" to MZ)"

  #find plan of current instance
  echo -e "$(yellow "####### Find plan of the service instance #######")"
  find_plan

  #create new service instance
  echo -e "$(yellow "####### Create Multi AZ instance #######")"
  create_service_instance

  #unbind the app from old service instance
  echo -e "$(yellow "####### Stop currently binded app and unbind them #######")"
  unbind_app

  #Find service keys if any, and store the names of the keys
  echo -e "$(yellow "####### Find service keys associated with service instance (if any) #######")"
  find_service_keys

  #Take backup
  echo -e "$(yellow "####### Take backup of current service instance #######")"
  take_backup

  #if [ ! -z ${backup_guid:-} ]; then
  #  echo -e "red Backup guid not found !!"
  #  exit 1
  #fi

  #restore backup to new instance
  echo -e "$(yellow "####### Restore backup on new service instance #######")"
  restore_backup

  #rename old instance as old
  echo -e "$(yellow "####### Exchange the names of the service instances #######")"
  cf rename-service "$service_name" "$service_name-old"

  #rename new instance as old
  cf rename-service "$service_name-dummy" "$service_name"

  #Bind the app to new instance and restage
  echo -e "$(yellow "####### Bind apps to new service instance (if any) & restage apps #######")"
  bind_apps_to_new_instance

  #create service keys
  echo -e "$(yellow "####### Create service keys (if any) #######")"
  create_service_keys

  echo -e "$(green Migration of "$service_name" completed !!)"
}

function check_if_migration_required() {

  echo -e "$(cyan "Check if migration required !!" )"
  echo -e "$(cyan Checking service "$service_name" )"

  IS_SERVICE_EXISTS="$(cf curl "/v2/service_instances?q=name%3A$service_name" | jq '.total_results')"
  if [ "$IS_SERVICE_EXISTS" ==  "0" ]; then
    echo -e "$(red Service $service_name does not exist. Exiting..)"
    exit 0
  fi

  DEPLOYMENT_NAME="$("$BROKER_SCRIPT" info "$service_name" | jq -r '.details.deployment_name')"
  bosh_login "$DEPLOYMENT_NAME"

  cnt=0

  while [ "$cnt" -lt 5 ]; do
    az="$(bosh -e "$BOSH_NAME" -d "${DEPLOYMENT_NAME}" vms --column=AZ --json | jq .Tables[0].Rows[$cnt].az | awk -F"\"" '{print $2}')"
    if [ "$az" == "z2" ]; then
      echo -e "$(green Its already in multi AZ no need of migration)"
      exit 0
    fi
    cnt=$((cnt+1))
  done

  echo "Its single. Lets migrate to multi AZ !!"
}

########################################
# Start Migration                      #
########################################
echo -e "$(yellow "############ Start of migration ############ $(date +"%Y-%m-%dT%T") ")"

if [ "$#" -ne 3 ]; then
    echo -e "$(red please provide <cf-org> <cf-space> <service-name> as input)"
    exit 1
fi

cf_org_name="$1"
cf_space_name="$2"
service_name="$3"

# Login to CF
cf_login "$cf_org_name" "$cf_space_name"

check_if_migration_required

migrate_instance

echo -e "$(yellow "############ End of migration ############## $(date +"%Y-%m-%dT%T") ")"
