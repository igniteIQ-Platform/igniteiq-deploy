# Terraform state lives in the CUSTOMER's project (D3). The bucket must exist
# BEFORE `terraform init` (Cloud Shell is ephemeral — local state would be lost).
# The wizard's bootstrap creates it, then uncomments this block. Left commented
# so the module validates/inits with local state during development.
#
# terraform {
#   backend "gcs" {
#     bucket = "REPLACED_BY_BOOTSTRAP"   # e.g. <project>-igniteiq-tfstate
#     prefix = "depot"
#   }
# }
