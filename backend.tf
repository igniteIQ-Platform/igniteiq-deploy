# Terraform state lives in the CUSTOMER's project (D3), in a bucket that
# scripts/bootstrap_state.sh creates before `terraform init` (Cloud Shell is ephemeral, so
# local state would be lost).
#
# A partial configuration: the bucket differs per project, so it is supplied at init and
# never written into this file.
#
#   terraform init -backend-config="bucket=<project>-igniteiq-tfstate"
#
# scripts/deploy.sh does that for you. To validate without any state, as CI does:
#
#   terraform init -backend=false
terraform {
  backend "gcs" {
    prefix = "depot"
  }
}
