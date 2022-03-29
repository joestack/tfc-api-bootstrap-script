#!/bin/bash

logdir="./logs"
#timestamp=`date +%g%m%d_%H%M%S`
#log="$logdir/$timestamp.log"
#workdir="./tmp"

[[ -d $logdir ]] || mkdir $logdir
#[[ -d $workdir ]] || mkdir $workdir

source environment.conf

cd $logdir

if [[ ! -e ~/.terraform.d/credentials.tfrc.json ]] ; then 
  echo "no TFC token found: terraform login" && exit 1
else
  tfc_token=$(cat ~/.terraform.d/credentials.tfrc.json | grep token | tr -d "\"" | cut -d : -f2)
fi

check_doormat() {
  if [[ $(doormat aws --list) ]] ; then
   echo "doormat is initialized"
  else
   echo "doormat is not initialized: doormat --refresh" && exit 1
  fi
}

if [[ $(echo $inject_cloud_credentials) = "true" ]] ; then
  echo "checking doormat..." && check_doormat
fi


#tfc_token=$(cat ~/.terraform.d/credentials.tfrc.json | grep token | tr -d "\"" | cut -d : -f2)


################################################
# Request the TF[C/E] VCS-Provider oauth-token #
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
sed -e "s/placeholder/$workspace/" < ../api-data/workspace.template.json > workspace.json

# Create workspace 
workspace_result=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
       --header "Content-Type: application/vnd.api+json" \
       --request POST \
	     --data @workspace.json \
       "https://${address}/api/v2/organizations/${organization}/workspaces"
)

echo "Workspace $workspace has been created" && echo

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
      -e "s/my-sensitive/$sensitive/" < ../api-data/variable.template.json  > variable-$stamp.json
  
  echo "Adding variable $key in category $category "
  
  upload_variable_result=$(
    curl -Ss \
         --header "Authorization: Bearer $tfc_token" \
         --header "Content-Type: application/vnd.api+json" \
         --data @variable-$stamp.json \
         "https://${address}/api/v2/vars?filter%5Borganization%5D%5Bname%5D=${organization}&filter%5Bworkspace%5D%5Bname%5D=${workspace}"
  )
done < ../variables.csv

}

################################
# Step 2.1: INJECT CREDENTIALS #
################################
inject_cloud_credentials() {

doormat aws -r $doormat_arn --tf-push --tf-organization $organization --tf-workspace $workspace

echo "Cloud credentials have been injected" && echo
}



# ##########################################
# # Step 3: (optionally) CREATE POLICY-SET #
# ##########################################
# create_policyset() {

# # Create payload.json from template 
# sed -e "s/oauth_token/$oauth_token/" \
#     -e "s/policyset_name/$policyset_name/" \
#     -e "s/policyset_path/$policyset_path/" \
#     -e "s/policyset_repo/$policyset_repo/" \
#     -e "s/policyset_branch/$policyset_branch/" < ../api-data/create-policy-set.template.json > create-policy-set.json

# # Create policy-set
# policy_set_result=$(
#   curl -Ss \
#        --header "Authorization: Bearer $tfc_token" \
# 	     --header "Content-Type: application/vnd.api+json" \
# 	     --request POST \
# 	     --data @create-policy-set.json \
# 	     "https://${address}/api/v2/organizations/${organization}/policy-sets"
# )

# echo "Policy-Set has been created" && echo

# }


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
sed -e "s/workspace_id/$workspace_id/" < ../api-data/attach-policy-set.template.json > attach-policy-set.json

# Attach the the workspace-id to policy-set-id
attach_policy_set=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
       --header "Content-Type: application/vnd.api+json" \
       --request POST \
       --data @attach-policy-set.json \
       "https://${address}/api/v2/policy-sets/${policy_set_id}/relationships/workspaces"
)

echo "Policy-Set ${pcs// /} has been attached to Workspace ${workspace}"
done

echo
}


########################################
# Step 4: ASSIGN VCS REPO TO WORKSPACE #
########################################
add_vcs_to_workspace() {

#Setup VCS repo and additional parameters (auto-apply, queue run in workspace-vcs.json
sed -e "s/placeholder/$workspace/" \
    -e "s/vcs_repo/$vcs_repo/" \
    -e "s/oauth_token/$oauth_token/" < ../api-data/workspace-vcs.template.json  > workspace-vcs.json

# Patch workspace
workspace_vcs=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
	     --header "Content-Type: application/vnd.api+json" \
	     --request PATCH \
	     --data @workspace-vcs.json \
	     "https://${address}/api/v2/organizations/${organization}/workspaces/${workspace}"
)

echo "VCS has been assigned to Workspace..."

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
    -e "s/queue_all_runs/$queue_all_runs/" < ../api-data/workspace-settings.template.json  > workspace-settings.json

# Patch workspace
workspace_vcs=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
	     --header "Content-Type: application/vnd.api+json" \
	     --request PATCH \
	     --data @workspace-settings.json \
	     "https://${address}/api/v2/organizations/${organization}/workspaces/${workspace}"
)

echo "Finalized Workspace settings!"

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

  sed -e "s/workspace_id/$workspace_id/" < ../api-data/trigger-run.template.json  > trigger-run.json

  apply-run=$(
    curl -Ss \
         --header "Authorization: Bearer $tfc_token" \
         --header "Content-Type: application/vnd.api+json" \
         --request POST \
         --data @trigger-run.json \
         "https://${address}/api/v2/runs"
  ) > /dev/null 2>&1

  echo "A Run on $workspace is initiated..."

}



##################
## MAIN SECTION ##
##################
create_workspace
create_variables
[[ $(echo $inject_cloud_credentials) = "true" ]] && inject_cloud_credentials
[[ $(echo $assign_vcs_to_workspace) = "true" ]] && get_oauth_token
#[[ $(echo $create_policyset) = "true" || $(echo $assign_vcs_to_workspace) = "true" ]] && get_oauth_token
#[[ $(echo $create_policyset) = "true" ]] && create_policyset
[[ $(echo $attach_workspace2policyset) = "true" ]] && attach_workspace2policyset
[[ $(echo $assign_vcs_to_workspace) = "true" ]] && add_vcs_to_workspace
add_workspace_settings
[[ $(echo $trigger_run) = "true" ]] && trigger_run

