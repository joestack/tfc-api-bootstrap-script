# tfc-api-bootstrap-script
Using the Terraform Enterprise/Cloud API to generate Workspace, Variables, VCS connection, assign Policies and trigger a run.

This allows a very simple Continuous Infrastructure Automation (CIA) pipeline consisting of only two components. A version control system and Terraform Cloud or Terraform Enterprise. 

This enables:
- Programmatic generation of Terraform Workspaces and Landing Zones, respectively.
- The secure injection of secrets like cloud credentials as workspace variables (the secret-zero that enables the workflow).
- The segregation of responsibilities in the form of CIA Pipleline Publisher (admin) and Pipeline Consumer (IaC developer). 


## environment.conf 
to customize your specific needs in terms of workspace to be generated, VCS repo to be assigned, policies to be used, etc...

## variables.csv
to assign your specific terraform and environment variables. Mark them as sensitive if needed so that nobody else will ever see them. The format is: Key,Value,terraform or environment variable,HCL true/false, sensitive true/false


Finally run the **create_tfe_environment.sh** script to create or re-create your infrastructure/workload based on the IaC declaration that resides in a version control system.   


## Quick HowTo
a) Clone the repo on your local machine (Linux/Mac)

b) Copy the create_tfe_environment.sh script into a folder that is part of your $PATH i.e. /usr/local/bin just to make the script globally available on your system. You can also skip that step and run the script directly from its local folder.

c) Copy the api-data folder to a place on your system (i.e. /usr/local/lib) to make its content globally available as well. You can skip this step and keep the api-data in its local folder. The existens of a local api-data folder has always precedence.

d) If you decided to use a global folder for the api-data, edit the *create_tfe_environment.sh* script and update the *api_data_dir=~/api-data* to your specific requirement (i.e.api_data_dir=/usr/local/lib/api-data). 

