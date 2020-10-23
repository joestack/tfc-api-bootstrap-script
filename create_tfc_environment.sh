#!/bin/bash

if [[ ! -e ~/.terraform.d/credentials.tfrc.json ]] ; then 
  echo "no TFC token found: terraform login" && exit 1
fi

if [[ $(doormat aws --list) ]] ; then
  echo "doormat is initialized"
else
 echo "doormat is not initialized: doormat --refresh" && exit 1
fi

source environment.conf


tfc_token=$(cat ~/.terraform.d/credentials.tfrc.json | grep token | tr -d "\"" | cut -d : -f2)

# Request the TF[C/E] VCS-Provider oauth-token
oauth_token=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
       --header "Content-Type: application/vnd.api+json" \
       --request GET \
       "https://${address}/api/v2/organizations/${organization}/oauth-clients" |\
  jq -r ".data[] | select (.attributes.name == \"$vcs_provider\") | .relationships.\"oauth-tokens\".data[].id "
)




########################
# 01) CREATE WORKSPACE #
########################
create_workspace() {


# Set name of workspace in workspace.json (create a payload.json)
sed -e "s/placeholder/$workspace/" < api-data/workspace.template.json > workspace.json

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


#####################################
# 02) ASSIGN VARIABLES TO WORKSPACE #
#####################################
create_variables() {


# Add variables to workspace
while IFS=',' read -r key value category hcl sensitive
do
  sed -e "s/my-organization/$organization/" \
      -e "s/my-workspace/$workspace/" \
      -e "s/my-key/$key/" \
      -e "s/my-value/$value/" \
      -e "s/my-category/$category/" \
      -e "s/my-hcl/$hcl/" \
      -e "s/my-sensitive/$sensitive/" < api-data/variable.template.json  > variable.json
  
  echo "Adding variable $key in category $category "
  
  upload_variable_result=$(
    curl -Ss \
         --header "Authorization: Bearer $tfc_token" \
         --header "Content-Type: application/vnd.api+json" \
         --data @variable.json \
         "https://${address}/api/v2/vars?filter%5Borganization%5D%5Bname%5D=${organization}&filter%5Bworkspace%5D%5Bname%5D=${workspace}"
  )
done < variables.csv

# INJECT CREDENTIALS #
doormat aws -r arn:aws:iam::711129375688:role/se_demos_dev-developer --tf-push --tf-organization $organization --tf-workspace $workspace


echo "Variables have been assigned" && echo

}


#########################
# 03) CREATE POLICY-SET #
#########################
create_policyset() {


# Create payload.json from template 
sed -e "s/oauth_token/$oauth_token/" \
    -e "s/policyset_name/$policyset_name/" \
    -e "s/policyset_path/$policyset_path/" \
    -e "s/policyset_repo/$policyset_repo/" \
    -e "s/policyset_branch/$policyset_branch/" < api-data/create-policy-set.template.json > create-policy-set.json

# Create policy-set
policy_set_result=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
	     --header "Content-Type: application/vnd.api+json" \
	     --request POST \
	     --data @create-policy-set.json \
	     "https://${address}/api/v2/organizations/${organization}/policy-sets"
)

echo "Policy-Set has been created" && echo

}




######################################
# 04) ATTACH POLICY-SET TO WORKSPACE #
######################################
attach_workspace2policyset() {

# Retrieve workspace ID as prerequisite to attach a policy-set to that workspace
workspace_id=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
       --header "Content-Type: application/vnd.api+json" \
       "https://${address}/api/v2/organizations/${organization}/workspaces" |\
  jq -r ".data[] | select (.attributes.name == \"$workspace\") | .id"
)

# Retrieve the ID of the policy-set 
policy_set_id=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
       "https://${address}/api/v2/organizations/${organization}/policy-sets" |\
  jq -r ".data[] | select (.attributes.name == \"${policyset_name}\") | .id"
)

# Create payload.json from template
sed -e "s/workspace_id/$workspace_id/" < api-data/attach-policy-set.template.json > attach-policy-set.json

# Attach the the workspace-id to policy-set-id
attach_policy_set=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
       --header "Content-Type: application/vnd.api+json" \
       --request POST \
       --data @attach-policy-set.json \
       "https://${address}/api/v2/policy-sets/${policy_set_id}/relationships/workspaces"
)

echo "Policy-Set has been attached to Workspace" && echo

}



#############################################################
# 05) ASSIGN VCS REPO TO WORKSPACE AND TRIGGER PLAN & APPLY #
#############################################################
patch_vcs2ws_and_run() {


#Setup VCS repo and additional parameters (auto-apply, queue run in workspace-vcs.json
sed -e "s/placeholder/$workspace/" \
    -e "s/vcs_repo/$vcs_repo/" \
    -e "s/oauth_token/$oauth_token/" < api-data/workspace-vcs.template.json  > workspace-vcs.json

# Patch workspace
workspace_vcs=$(
  curl -Ss \
       --header "Authorization: Bearer $tfc_token" \
	     --header "Content-Type: application/vnd.api+json" \
	     --request PATCH \
	     --data @workspace-vcs.json \
	     "https://${address}/api/v2/organizations/${organization}/workspaces/${workspace}"
)

echo "Apply is running..."

}




##################
## MAIN SECTION ##
##################

create_workspace
create_variables
[[ $(echo $create_policyset) = "true" ]] && create_policyset
[[ $(echo $attach_workspace2policyset) = "true" ]] && attach_workspace2policyset
patch_vcs2ws_and_run
