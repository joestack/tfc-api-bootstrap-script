# tfc-api-bootstrap-script
Using the Terraform Enterprise/Cloud API to generate a Workspace, injecting Variables, connect VCS repository, assigning Policies, and trigger a run.

This allows a very simple Continuous Infrastructure Automation (CIA) pipeline consisting of only two components - A version control system and Terraform Cloud/Enterprise. 

This enables:
- Programmatic generation of Terraform Workspaces and Landing Zones, respectively.
- The secure injection of secrets like cloud credentials as workspace variables (the secret-zero that enables the workflow).
- The segregation of responsibilities in the form of CIA Pipleline Publisher (admin) and Pipeline Consumer (IaC developer). 


## environment.conf 
to customize your specific needs in terms of workspace to be generated, VCS repo to be assigned, policies to be used, etc...

## variables.csv
to assign your specific terraform and environment variables. Mark them as sensitive if needed so that nobody else will ever see them. The format is: Key,Value,terraform or environment variable,HCL true/false, sensitive true/false


Finally run the **tf_bootstrap_lz.sh** script to create or re-create your infrastructure/workload based on the IaC declaration that resides in a version control system.   


## Quick HowTo
a) Clone the repo on your local machine (Linux/Mac)

b) Copy the tf_bootstrap_lz.sh script into a folder that is part of your $PATH i.e. /usr/local/bin just to make the script globally available on your system. You can also skip that step and run the script directly from its local folder.

c) Define your specific **environments.conf** and **variables.csv** and run the script.