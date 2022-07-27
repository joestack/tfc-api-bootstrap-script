#!/bin/bash
version=220727-01

#set -o xtrace

##TODO
# DONE: check if jq is installed
#
# DONE: add command line feature to inject/give precedence to a environment.conf and variables.csv
#
# DONE: add command line feature to renew cloud credentials only
#
# DONE: make the script and api-data libraries globally available
# and give local existence of api-data precedence
#
# add azure and gcp cloud credentials. A combination of several cloud providers should be possible also.
#
# DONE: improve debugging capabilities
#
# DONE: Add log and is command installed utility functions
# 
# Validate environment.conf
#
# Validate variables.csv
#
# Remove necessity for escapes in environment.conf
#
# Simplify curl executions -> utility function

# api_data_dir - The global folder that contains the api-data templates. The existence of that folder in the current directory got precedence!
api_data_dir=~/api-data
workdir=$(pwd)
logdir=$workdir/logs

[[ -d $logdir ]] || mkdir $logdir

cd $logdir

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
    echo "[-v]   Version Info"
    echo "[-c]   Update cloud credentials to Workspace only"
    echo
}

# Utility function to log output
log() {
    local log_text="$1"
    local log_level="$2"
    local log_color="$3"

    echo -e "${log_color}[$(date +"%Y-%m-%d %H:%M:%S %Z")] [${log_level}] ${log_text} ${LOG_DEFAULT_COLOR}";
    return 0;
}

log_info()      { log "$1" "INFO" "\033[1m"; }
log_debug()     { log "$1" "DEBUG" "\033[1;34m"; }
log_success()   { log "$1" "SUCCESS" "\033[1;32m"; }
log_error()     { log "$1" "ERROR" "\033[1;31m"; }

# Utlity function to check if required software is available
is_command_installed() {
    local command_to_check="$1"

    if ! command -v ${command_to_check} &> /dev/null
    then
        log_error "${command_to_check} could not be found. Please install it."
        exit 1
    else
        log_success "${command_to_check} could be found."
    fi
}

check_environment() {
    if [[ ! -e $workdir/environment.conf ]] ; then
        log_error "no environment.conf file found in $workdir" && exit 1
    else
        source $workdir/environment.conf
        log_success "environment.conf successfully sourced."
    fi
}

check_variables() {
    if [[ ! -e $workdir/variables.csv ]] ; then
        log_error "no variables.csv file found in $workdir" && exit 1
    fi
}

check_api_data() {
    if [[ -d $workdir/api-data ]] ; then
        log_success "Using api-data declarations found in $workdir/api-data"
        api_data=$workdir/api-data
    elif [[ -d $api_data_dir ]] ; then
        log_success "Using api-data declarations found globally in $api_data_dir"
        api_data=$api_data_dir
    else
        log_error "No api-data found. Please provide them in $workdir/api-data or in ~/api-data" && exit 1
    fi
}

check_tfc_token() {
    if [[ ! -e ~/.terraform.d/credentials.tfrc.json ]] ; then
        log_error "No TFC/TFE token found. Please execute 'terraform login'" && exit 1
    else
        tfc_token=$(cat ~/.terraform.d/credentials.tfrc.json | jq -r ".credentials.\"${address}\".token ")
        log_success "Using TFC/TFE token from ~/.terraform.d/credentials.tfrc.json"
    fi
}

check_doormat() {
    if [[ $(doormat aws list) ]] ; then
        log_success "doormat is initialized."
    else
        log_error "doormat has not been initialized. Please run 'doormat login'" && exit 1
    fi
}


################################################
# Request the TF[C/E] VCS-Provider oauth-token #
#    DEPRICATED !!!
################################################
get_oauth_token() {

    oauth_token=$(
        curl -Ss \
            --header "Authorization: Bearer $tfc_token" \
            --header "Content-Type: application/vnd.api+json" \
            --request GET \
            "https://${address}/api/v2/organizations/${organization}/oauth-clients" |\
            jq -r ".data[] | select (.attributes.name == \"$vcs_provider\") | .relationships.\"oauth-tokens\".data[].id "
    )
}


############################
# Step 1: CREATE WORKSPACE #
############################
create_workspace() {

    # Set name of workspace in workspace.json (create a payload.json)
    sed -e "s/placeholder/$workspace/" < $api_data/workspace.template.json > workspace.json

    # Create workspace
    workspace_result=$(
        curl -Ss \
            --header "Authorization: Bearer $tfc_token" \
            --header "Content-Type: application/vnd.api+json" \
            --request POST \
            --data @workspace.json \
            "https://${address}/api/v2/organizations/${organization}/workspaces"
    )

    log_success "Workspace $workspace has been created."
}


#########################################
# Step 2: ASSIGN VARIABLES TO WORKSPACE #
#########################################
create_variables() {

    # Add variables to workspace
    while IFS=',' read -r key value category hcl sensitive
    do
        stamp=`date +%S-%N`

        sed -e "s/my-organization/$organization/" \
            -e "s/my-workspace/$workspace/" \
            -e "s/my-key/$key/" \
            -e "s/my-value/$value/" \
            -e "s/my-category/$category/" \
            -e "s/my-hcl/$hcl/" \
            -e "s/my-sensitive/$sensitive/" < $api_data/variable.template.json  > variable-$stamp.json

        upload_variable_result=$(
            curl -Ss \
                --header "Authorization: Bearer $tfc_token" \
                --header "Content-Type: application/vnd.api+json" \
                --data @variable-$stamp.json \
                "https://${address}/api/v2/vars?filter%5Borganization%5D%5Bname%5D=${organization}&filter%5Bworkspace%5D%5Bname%5D=${workspace}"
        )

        log_success "Adding variable $key in category $category "
    done < ../variables.csv
}

################################
# Step 2.1: INJECT CREDENTIALS #
################################
inject_cloud_credentials() {
    doormat aws -r $doormat_arn tf-push --organization $organization --workspace $workspace &> /dev/null

    log_success "Cloud credentials have been injected."
}


#########################################################
# Step 3.1: ATTACH POLICY-SET TO WORKSPACE #
#########################################################
attach_workspace2policyset() {
    # Retrieve workspace ID as prerequisite to attach a policy-set to that workspace
    workspace_id=$(
        curl -Ss \
            --header "Authorization: Bearer $tfc_token" \
            --header "Content-Type: application/vnd.api+json" \
            "https://${address}/api/v2/organizations/${organization}/workspaces" |\
            jq -r ".data[] | select (.attributes.name == \"$workspace\") | .id"
    )

    IFS=","
    for pcs in $policyset_name
    do

        # Retrieve the ID of the policy-set
        # ${pcs// /} was ${policyset_name}
        policy_set_id=$(
            curl -Ss \
                --header "Authorization: Bearer $tfc_token" \
                "https://${address}/api/v2/organizations/${organization}/policy-sets" |\
                jq -r ".data[] | select (.attributes.name == \"${pcs// /}\") | .id"
        )

        # Create payload.json from template
        sed -e "s/workspace_id/$workspace_id/" < $api_data/attach-policy-set.template.json > attach-policy-set.json

        # Attach the the workspace-id to policy-set-id
        attach_policy_set=$(
            curl -Ss \
                --header "Authorization: Bearer $tfc_token" \
                --header "Content-Type: application/vnd.api+json" \
                --request POST \
                --data @attach-policy-set.json \
                "https://${address}/api/v2/policy-sets/${policy_set_id}/relationships/workspaces"
        )

        log_success "Policy-Set ${pcs// /} has been attached to Workspace ${workspace}"
    done
}


########################################
# Step 4: ASSIGN VCS REPO TO WORKSPACE #
########################################
add_vcs_to_workspace() {

    ##//NEW
    if [[ "$vcs_repo" == *\\* ]]
    then
        vcs_repo=$vcs_repo
    else
        vcs_repo=$(echo $vcs_repo | sed 's/\//\\\//g')
    fi
    ##NEW//

    #Setup VCS repo and additional parameters (auto-apply, queue run in workspace-vcs.json
    sed -e "s/placeholder/$workspace/" \
        -e "s/vcs_repo/$vcs_repo/" \
        -e "s/oauth_token/$vcs_provider_oauth_token_id/" < $api_data/workspace-vcs.template.json  > workspace-vcs.json

    # Patch workspace
    workspace_vcs=$(
        curl -Ss \
            --header "Authorization: Bearer $tfc_token" \
            --header "Content-Type: application/vnd.api+json" \
            --request PATCH \
            --data @workspace-vcs.json \
            "https://${address}/api/v2/organizations/${organization}/workspaces/${workspace}"
    )

    log_success "VCS repo has been connected to workspace ${workspace}."
}


###############################################
# Step 5: ADDING ALL OTHER WORKSPACE SETTINGS #
###############################################
add_workspace_settings() {

    #Setup VCS repo and additional parameters (auto-apply, queue run in workspace-vcs.json
    sed -e "s/placeholder/$workspace/" \
        -e "s/terraformversion/$terraform_version/" \
        -e "s/global_remote_state/$global_remote_state/" \
        -e "s/auto_apply/$auto_apply/" \
        -e "s/queue_all_runs/$queue_all_runs/" < $api_data/workspace-settings.template.json  > workspace-settings.json

    # Patch workspace
    workspace_vcs=$(
        curl -Ss \
            --header "Authorization: Bearer $tfc_token" \
            --header "Content-Type: application/vnd.api+json" \
            --request PATCH \
            --data @workspace-settings.json \
            "https://${address}/api/v2/organizations/${organization}/workspaces/${workspace}"
    )

    log_success "Workspace settings have been successfully applied."
}


#######################################
# Step 6: TRIGGER A RUN ON WORKSPACE  #
#######################################
trigger_run() {

    workspace_id=$(
        curl -Ss \
            --header "Authorization: Bearer $tfc_token" \
            --header "Content-Type: application/vnd.api+json" \
            "https://${address}/api/v2/organizations/${organization}/workspaces" |\
            jq -r ".data[] | select (.attributes.name == \"$workspace\") | .id"
    )

    sed -e "s/workspace_id/$workspace_id/" < $api_data/trigger-run.template.json  > trigger-run.json

    apply-run=$(
        curl -Ss \
            --header "Authorization: Bearer $tfc_token" \
            --header "Content-Type: application/vnd.api+json" \
            --request POST \
            --data @trigger-run.json \
            "https://${address}/api/v2/runs"
    ) > /dev/null 2>&1

    log_success "A Terraform run on $workspace has been initiated."

}

while getopts ":hvc" opt; do
    case ${opt} in
        h )
            usage
            exit 0
            ;;
        v )
            echo $version
            exit 0
            ;;
        c )
            check_environment
            check_doormat
            check_tfc_token
            inject_cloud_credentials
            exit 0
            ;;
        \? )
            echo "Invalid Option: -$OPTARG" 1>&2
            exit 1
            ;;
    esac
done
shift $((OPTIND -1))

##################
## MAIN SECTION ##
##################

log_info "\nPREREQUISITES:\nPlease make sure that you have a TFC/TFE organization available and configured in the environment.conf. \nIf you are using Sentinel policies, you need to have a TFC organization with Business subscription or TFE with Governance&Policy module enabled. \nThe organization must have a VCS Provider configured as well."

is_command_installed "jq"
is_command_installed "sed"
is_command_installed "doormat"
is_command_installed "curl"

check_environment
check_api_data
check_variables
check_tfc_token
[[ $inject_cloud_credentials = "true" ]] && check_doormat

create_workspace
create_variables
[[ $inject_cloud_credentials = "true" ]] && inject_cloud_credentials
[[ $attach_workspace2policyset = "true" ]] && attach_workspace2policyset
[[ $assign_vcs_to_workspace = "true" ]] && add_vcs_to_workspace
add_workspace_settings
[[ $trigger_run = "true" ]] && trigger_run

