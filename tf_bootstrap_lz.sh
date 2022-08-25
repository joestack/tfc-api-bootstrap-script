#!/bin/bash
version=220825

#set -o xtrace

##TODO
# DONE: check if jq is installed
# DONE: add command line feature to inject/give precedence to a environment.conf and variables.csv
# DONE: add command line feature to renew cloud credentials only
# DONE: make the script and api-data libraries globally available
# DONE: and give local existence of api-data precedence
# TODO: PRIO add azure and gcp cloud credentials. A combination of several cloud providers should be possible also.
#       IMPEDIMENT: DOORMAT still sucks. Each cloud provider has its own workflow/capabilities. 
# DONE: improve debugging capabilities
# DONE: Add log and is command installed utility functions
# TODO: Validate environment.conf
# DONE: Validate variables.csv
# DONE: Remove necessity for escapes in environment.conf
# DONE: Simplify curl executions -> utility function
# DONE: move command check to debug
# TODO: -a path to API data (prio1), local prio2, global (prio3), otherwise error
# TODO: -e environment.conf -> see -a
# IDEA: inject_variable=true/false flag
# IDEA: multiple levels of output -> like openssh -vvv
# DONE: generic approach to inject AWS cloud credentials into variables.csv
# TODO: generic approach to inject AZ cloud credentials into variables.csv
# TODO: generic approach to inject GCP cloud credentials into variables.csv
# TODO: Proper API call handling to update existing cloud credentials to workspace (PATCH or DELETE and CREATE
#       DONE: in case of AWS. Delete AWS Workspace Variables (credentials) if they exist
#       TODO: Azure
#       TODO: GCP 
# TODO: Ensure/CHeck that only the latest cloud credentials exist in variables.csv or as an IDEA: using a dedicated credentials.csv instead of variables.csv 


workdir=$(pwd)
logdir=$workdir/logs
debug=false
#pit=`date +%s@%N`
#pit=$(`date +%s@%N`)

[[ -d $logdir ]] || mkdir $logdir
cd $logdir

# Utility function to log output
log() {
    local log_text="$1"
    local log_level="$2"
    local log_color="$3"

    echo -e "${log_color}[$(date +"%Y-%m-%d %H:%M:%S %Z")] [${log_level}] ${log_text} ${LOG_DEFAULT_COLOR}";
    return 0;
}

log_info()      { log "$1" "INFO" "\033[1m"; }
log_debug()     { [[ "${debug}" = "true" ]] && log "$1" "DEBUG" "\033[1;34m"; }
log_success()   { log "$1" "SUCCESS" "\033[1;32m"; }
log_error()     { log "$1" "ERROR" "\033[1;31m"; }

# Utility function to simplify curl calls and handle relevant return codes
execute_curl() {
    local token="$1"
    local http_method="$2"
    local url="$3"
    local payload="$4"

    case $http_method in
        GET | DELETE)
            local result=$(curl -Ss \
                --header "Authorization: Bearer ${token}" \
                --header "Content-Type: application/vnd.api+json" \
                --request "${http_method}" \
            "${url}")
            ;;
        PATCH | POST)
            local result=$(curl -Ss \
                --header "Authorization: Bearer ${token}" \
                --header "Content-Type: application/vnd.api+json" \
                --request "${http_method}" \
                --data @${payload} \
            "${url}")
            ;;
        *)
            log_error "invalid tf_curl request" && exit 1
    esac

    echo "${result}"
}

# Utlity function to check if required software is available
is_command_installed() {
    local command_to_check="$1"

    if ! command -v ${command_to_check} &> /dev/null
    then
        log_error "${command_to_check} could not be found. Please install it."
        exit 1
    else
        log_debug "${command_to_check} could be found."
    fi
}

check_environment() {
    if [[ ! -e $workdir/environment.conf ]] ; then
        log_error "no environment.conf file found in $workdir" && exit 1
    else
        source $workdir/environment.conf
        log_debug "environment.conf successfully sourced."
    fi
}

check_variables() {
    if [[ ! -e $workdir/variables.csv ]] ; then
        log_error "no variables.csv file found in $workdir" && exit 1
    fi
}

check_tfc_token() {
    if [[ ! -e ~/.terraform.d/credentials.tfrc.json ]] ; then
        log_error "No TFC/TFE token found. Please execute 'terraform login'" && exit 1
    else
        tfc_token=$(cat ~/.terraform.d/credentials.tfrc.json | jq -r ".credentials.\"${address}\".token ")
        log_debug "Using TFC/TFE token from ~/.terraform.d/credentials.tfrc.json"
    fi
}

check_doormat() {
    if [[ $(doormat aws list) ]] ; then
        log_success "doormat is initialized."
    else
        log_error "doormat has not been initialized. Please run 'doormat login'" && exit 1
    fi
}

create_workspace_api() {
    local workspace="$1"
    pit=`date +%s@%N`

    tee $logdir/workspace-$pit.json > /dev/null <<EOF

{
  "data":
  {
    "attributes": {
      "name":"$workspace"
    },
    "type":"workspaces"
  }
}
EOF

    # Create workspace
    local result=$(
        execute_curl $tfc_token "POST" \
            "https://${address}/api/v2/organizations/${organization}/workspaces" "workspace-$pit.json"
    )

    log_debug "$(echo -e ${result} | jq -cM '. | @text ')"

    local link_to_workspace="https://${address}/app/${organization}/workspaces/${workspace}"
    log_success "Workspace $workspace has been created. Link to the workspace: ${link_to_workspace}"
}

inject_variable_api() {
    local key="$1"
    local value="$2"
    local category="$3"
    local hcl="$4"
    local sensitive="$5"
    pit=`date +%s@%N`

    tee $logdir/variable-$pit.json > /dev/null <<EOF
{
  "data": {
    "type":"vars",
    "attributes": {
      "key":"$key",
      "value":"$value",
      "category":"$category",
      "hcl":$hcl,
      "sensitive":$sensitive
    }
  },
  "filter": {
    "organization": {
      "username":"$organization"
    },
    "workspace": {
      "name":"$workspace"
    }
  }
}
EOF


    local result=$(
        execute_curl $tfc_token "POST" \
                "https://${address}/api/v2/vars?filter%5Borganization%5D%5Bname%5D=${organization}&filter%5Bworkspace%5D%5Bname%5D=${workspace}" \
                "variable-$pit.json"
        )

    log_debug "$(echo -e ${result} | jq -cM '. | @text ')"
    log_success "Adding variable $key in category $category "
}

delete_ws_variables_aws() {
    local all_ws_vars=$(
        execute_curl $tfc_token "GET" \
            "https://${address}/api/v2/vars?filter%5Borganization%5D%5Bname%5D=${organization}&filter%5Bworkspace%5D%5Bname%5D=${workspace}"
    )

    local var_id_aws_access_key_id=$(echo $all_ws_vars | jq -r ".data[] | select (.attributes.key == \"AWS_ACCESS_KEY_ID\") | .id ")
    local var_id_aws_secret_access_key=$(echo $all_ws_vars | jq -r ".data[] | select (.attributes.key == \"AWS_SECRET_ACCESS_KEY\") | .id ")
    local var_id_aws_session_token=$(echo $all_ws_vars | jq -r ".data[] | select (.attributes.key == \"AWS_SESSION_TOKEN\") | .id ")
    local var_id_aws_session_expiration=$(echo $all_ws_vars | jq -r ".data[] | select (.attributes.key == \"AWS_SESSION_EXPIRATION\") | .id ")
    

    [[ $var_id_aws_access_key_id != "" ]] && \
	    execute_curl $tfc_token "DELETE" "https://${address}/api/v2/vars/$var_id_aws_access_key_id"
    [[ $var_id_aws_secret_access_key != "" ]] && \
	    execute_curl $tfc_token "DELETE" "https://${address}/api/v2/vars/$var_id_aws_secret_access_key"
    [[ $var_id_aws_session_token != "" ]] && \
	    execute_curl $tfc_token "DELETE" "https://${address}/api/v2/vars/$var_id_aws_session_token"
    [[ $var_id_aws_session_expiration != "" ]] && \
	    execute_curl $tfc_token "DELETE" "https://${address}/api/v2/vars/$var_id_aws_session_expiration"
}

get_doormat_aws_credentials() {
    local aws_creds=$(doormat aws json -r $doormat_arn)
    local AWS_ACCESS_KEY_ID=$(echo $aws_creds | jq -r ".AccessKeyId")
    local AWS_SECRET_ACCESS_KEY=$(echo $aws_creds | jq -r ".SecretAccessKey")
    local AWS_SESSION_TOKEN=$(echo $aws_creds | jq -r ".SessionToken")
    local AWS_SESSION_EXPIRATION=$(echo $aws_creds | jq -r ".Expiration")

    inject_variable_api AWS_ACCESS_KEY_ID $AWS_ACCESS_KEY_ID env false false
    inject_variable_api AWS_SECRET_ACCESS_KEY $AWS_SECRET_ACCESS_KEY env false true
    inject_variable_api AWS_SESSION_TOKEN $AWS_SESSION_TOKEN env false true
    inject_variable_api AWS_SESSION_EXPIRATION $AWS_SESSION_EXPIRATION env false false
}

attach_workspace2policyset_api() {
    local workspace_id="$1"
    local policy_set_id="$2"
    local policy_set_name="$3"
    pit=`date +%s@%N`

    # Create payload.json
    tee $logdir/attach-policy-set-${pit}.json > /dev/null <<EOF
{
  "data": [
    { "id": "$workspace_id", "type": "workspaces" }
  ]
}
EOF

    # Attach the the workspace-id to policy-set-id
    local result_attach_policy_set=$(
        execute_curl $tfc_token "POST" \
            "https://${address}/api/v2/policy-sets/${policy_set_id}/relationships/workspaces" \
                "attach-policy-set-${pit}.json"
        )

    log_debug "$(echo -e ${result_attach_policy_set} | jq -cM '. | @text ')"
    log_success "Policy-Set ${policy_set_name} has been attached to Workspace ${workspace}"
}

add_vcs_to_workspace_api() {
    local workspace="$1"
    local vcs_repo="$2"
    local vcs_provider_oauth_token_id="$3"
    pit=`date +%s@%N`

    tee $logdir/workspace-vcs-$pit.json > /dev/null <<EOF
{
  "data": {
    "attributes": {
      "name": "$workspace",
      "working-directory": "",
      "vcs-repo": {
        "identifier": "$vcs_repo",
        "oauth-token-id": "$vcs_provider_oauth_token_id",
        "branch": "",
        "default-branch": true
      }
    },
    "type": "workspaces"
  }
}
EOF

    # Patch workspace
    local result=$(
        execute_curl $tfc_token "PATCH" \
            "https://${address}/api/v2/organizations/${organization}/workspaces/${workspace}" \
            "workspace-vcs-$pit.json"
    )

    log_debug "$(echo -e ${result} | jq -cM '. | @text ')"
    log_success "VCS repo has been connected to workspace ${workspace}."
}

add_workspace_settings_api() {
    local workspace="$1"
    local global_remote_state="$2"
    local auto_apply="$3"
    local queue_all_runs="$4"
    local terraform_version="$5"
    pit=`date +%s@%N`

    tee $logdir/workspace-settings-$pit.json > /dev/null <<EOF
{
    "data": {
      "attributes": {
        "name": "$workspace",
        "terraform_version": "$terraform_version",
        "global-remote-state": "$global_remote_state",
        "auto-apply": "$auto_apply",
        "queue-all-runs": "$queue_all_runs"
      },
      "type": "workspaces"
    }
  }
EOF

    # Patch workspace
    local result=$(
        execute_curl $tfc_token "PATCH" \
            "https://${address}/api/v2/organizations/${organization}/workspaces/${workspace}" \
            "workspace-settings-$pit.json"
    )

    log_debug "$(echo -e ${result} | jq -cM '. | @text ')"
    log_success "Workspace settings have been successfully applied."
}

trigger_run_api() {
    local workspace_id="$1"
    pit=`date +%s@%N`

    tee $logdir/trigger-run-$pit.json > /dev/null <<EOF
{
    "data": {
      "attributes": {
        "message": "IT Service Management via API"
      },
      "type":"runs",
      "relationships": {
        "workspace": {
          "data": {
            "type": "workspaces",
            "id": "$workspace_id"
          }
        }       
      }
    }
}
EOF

    local result_apply_run=$(
        execute_curl $tfc_token "POST" \
            "https://${address}/api/v2/runs" "trigger-run-$pit.json"
    )

    local run_id=$(echo $result_apply_run | jq -r .data.id)

    log_debug "$(echo -e ${result_apply_run} | jq -cM '. | @text ')"

    local link_to_run="https://${address}/app/${organization}/workspaces/${workspace}/runs/${run_id}"
    log_success "A Terraform run on $workspace has been initiated. Link to the run: ${link_to_run}"
}

destroy_run_api() {
    pit=`date +%s@%N`

    local result_get_workspace_id=$(
        execute_curl $tfc_token "GET" \
            "https://${address}/api/v2/organizations/${organization}/workspaces" |\
            jq -r ".data[] | select (.attributes.name == \"$workspace\") | .id"
    )
    
    tee $logdir/destroy-run-$pit.json > /dev/null <<EOF
{
  "data": {
    "attributes": {
      "message": "Destroy initiated by tf_bootstrap_script",
      "is-destroy": "true",
      "auto-apply": "true"	
    },
    "type":"runs",
    "relationships": {
      "workspace": {
        "data": {
          "type": "workspaces",
          "id": "$result_get_workspace_id"
        }
      }
    }
  }
}
EOF

    local result_destroy_run=$(
        execute_curl $tfc_token "POST" \
            "https://${address}/api/v2/runs" "destroy-run-$pit.json"
    )

    local run_id=$(echo $result_destroy_run | jq -r .data.id)

    log_debug "$(echo -e ${result_destroy_run} | jq -cM '. | @text ')"

    local link_to_run="https://${address}/app/${organization}/workspaces/${workspace}/runs/${run_id}"
    log_success "A Terraform destroy on $workspace has been initiated. Link to the run: ${link_to_run}"
}

# MAIN WORKFLOW 
# the [-b] flag

############################
# Step 1: CREATE WORKSPACE #
############################
create_workspace() {
    create_workspace_api $workspace
}

#########################################
# Step 2: ASSIGN VARIABLES TO WORKSPACE #
#########################################
create_variables() {
    # Add variables to workspace
    grep "^[^#;]" < $workdir/variables.csv | grep '^[[:alpha:]].*,[[:alpha:]].*,[[:alpha:]].*,[[:alpha:]].*,[[:alpha:]].*'|\
    while IFS=',' read -r key value category hcl sensitive
    do
        pit=`date +%s@%N`
        inject_variable_api $key $value $category $hcl $sensitive
    done
}

################################
# Step 2.1: INJECT CREDENTIALS #
################################
inject_cloud_credentials() {
    if [[ "${debug}" = "true" ]]; then
        doormat aws -r $doormat_arn tf-push --organization $organization --workspace $workspace
    else
        doormat aws -r $doormat_arn tf-push --organization $organization --workspace $workspace &> /dev/null
    fi
    log_success "Cloud credentials have been injected into the workspace via doormat."
}

#########################################################
# Step 3.1: ATTACH POLICY-SET TO WORKSPACE #
#########################################################
attach_workspace2policyset() {
    # Retrieve workspace ID as prerequisite to attach a policy-set to that workspace
    local workspace_id=$(
        execute_curl $tfc_token "GET" \
            "https://${address}/api/v2/organizations/${organization}/workspaces" |\
            jq -r ".data[] | select (.attributes.name == \"$workspace\") | .id"
    )
    
    for i in ${!policyset_names[*]}
    do
        local policy_set_id=$(
            execute_curl $tfc_token "GET" \
                "https://${address}/api/v2/organizations/${organization}/policy-sets" |\
                jq -r ".data[] | select (.attributes.name == \"${policyset_names[$i]// /}\") | .id"
        )
    
        attach_workspace2policyset_api $workspace_id $policy_set_id ${policyset_names[$i]// /}
    done
}

########################################
# Step 4: ASSIGN VCS REPO TO WORKSPACE #
########################################
add_vcs_to_workspace() {
    if [[ "$vcs_repo" == *\\* ]]
    then
        vcs_repo=$vcs_repo
    else
        vcs_repo=$(echo $vcs_repo | sed 's/\//\\\//g')
    fi
   
    add_vcs_to_workspace_api $workspace $vcs_repo $vcs_provider_oauth_token_id
}

###############################################
# Step 5: ADDING ALL OTHER WORKSPACE SETTINGS #
###############################################
add_workspace_settings() {
    add_workspace_settings_api $workspace $global_remote_state $auto_apply $queue_all_runs $terraform_version
}

#######################################
# Step 6: TRIGGER A RUN ON WORKSPACE  #
#######################################
trigger_run() {
    local result_get_workspace_id=$(
        execute_curl $tfc_token "GET" \
            "https://${address}/api/v2/organizations/${organization}/workspaces" |\
            jq -r ".data[] | select (.attributes.name == \"$workspace\") | .id"
    )

    log_debug "Workspace ID: ${result_get_workspace_id}"

    trigger_run_api $result_get_workspace_id
}

usage() {
    echo
    echo "$(basename "$0") -- programmatically create a Terraform [Cloud|Enterprise] Landing-Zone"
    echo
    echo "Create a Workspace, inject Variables, connect VCS repository, assign Policies via API"
    echo "Publish a VCS-driven pipeline from an administrative perspective"
    echo "that can be used by a developer or team of developers in a self service manner"
    echo "(separation of duties)".
    echo
    echo "https://github.com/joestack/tfc-api-bootstrap-script.git for more details"
    echo
    echo
    echo "[-h]   Print this help message"
    echo "[-b]   Bootstrap the environment based on environment.conf and variables.csv"
    #echo "[-e]   TODO /PATH/TO/environment.conf - override the workdir as location for the environment.conf file"
    #echo "[-v]   TODO /PATH/TO/variables.csv - override the workdir as location for the variables.csv file"
    echo "[-c]   Inject AWS cloud credentials to Workspace via Doormat (only AWS is supported by Doormat)"
    #echo "[-i]   Inject AWS cloud credentials via native API calls"
    echo "[-X]   Destroy run on Workspace to delete all resources"
    echo "[-d]   Print Debug output"
    echo "[-V]   Version Info"
    echo
}

log_debug "\nPREREQUISITES:\nPlease make sure that you have a TFC/TFE organization available and configured in the environment.conf. \nIf you are using Sentinel policies, you need to have a TFC organization with Business subscription or TFE with Governance&Policy module enabled. \nThe organization must have a VCS Provider configured as well."

are_commands_installed() {
    is_command_installed "jq"
    is_command_installed "sed"
    is_command_installed "doormat"
    is_command_installed "grep"
    is_command_installed "curl"
    is_command_installed "terraform"
}

while getopts ":hVciXbd" opt; do
    case ${opt} in
        h )
            usage
            exit 2
            ;;
        V )
            echo $version
            exit 0
            ;;
        e )
            # define path to environment.conf
            # to override $workdir as default location  
            ;;
        v )
            # define path to variables.csv
            # to override $workdir as default location
            ;;
        X )
            # Destroy all resouces 
            # Delete Workspace
            # ensure to destroy before delete (destroy without delete ->OK, delete without destroy ->NOT)
	    are_commands_installed
            check_environment
            check_tfc_token
            destroy_run_api
            ;; 
        c )
            # non generic doormat solution that works for AWS only 'doormat aws tf-push ...'
	    are_commands_installed
            check_environment
            check_doormat
            check_tfc_token
            inject_cloud_credentials
            ;; 
        i )
            # more generic (but doormat seems to be broken when using 'doormat aws -json ...')
	    are_commands_installed
            check_environment
            check_doormat
            check_tfc_token
            delete_ws_variables_aws
            get_doormat_aws_credentials
            exit 0 # TO BE REMOVED
            ;;
       b )
            # bootstrap main
	    are_commands_installed
            check_environment
            check_variables
            check_tfc_token
            [[ $inject_cloud_credentials = "true" ]] && check_doormat
            create_workspace
            create_variables
            [[ $inject_cloud_credentials = "true" ]] && inject_cloud_credentials
            #[[ $inject_cloud_credentials = "true" ]] && get_doormat_aws_credentials
            [[ $attach_workspace2policyset = "true" ]] && attach_workspace2policyset
            [[ $assign_vcs_to_workspace = "true" ]] && add_vcs_to_workspace
            add_workspace_settings
            [[ $trigger_run = "true" ]] && trigger_run
            ;;
         d )
            debug=true
            ;;
        \? )
            echo "Invalid Option: -$OPTARG" 1>&2
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))
