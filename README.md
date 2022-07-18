# tfc-api-bootstrap-script
Using the Terraform Enterprise/Cloud API to generate Workspace, Variables, VCS connection, assign Policies and trigger a run.

## environment.conf 
to customize your specific needs in terms of workspace to be generated, VCS repo to be assigned, policies to be used, etc...

## variables.csv
to assign your specific terraform and environment variables. Mark them as sensitive if needed so that nobody else will ever see them. The format is: Key,Value,terraform or environment variable,HCL true/false, sensitive true/false


Finally run the **create_tfe_environment.sh** script to create or re-create your infrastructure/workload based on the IaC declaration that resides in a version control system.   
