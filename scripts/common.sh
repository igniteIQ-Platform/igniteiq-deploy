# shellcheck shell=bash
# Sourced by the scripts, not run. Holds what more than one script has to agree on.

# tfvars_get <key> [file]
# Prints the value of a quoted string assignment (key = "value") in a tfvars file, or nothing
# when the key is absent. Returns 1 only when the file itself is missing.
# Character classes, not \s: this runs in the customer's shell (see AGENTS.md).
tfvars_get() {
  local key="$1" file="${2:-${TFVARS_FILE:-terraform.tfvars}}"
  [[ -f "${file}" ]] || return 1
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "${file}" | head -n 1
}

# state_bucket <project_id>
# The bucket that holds this project's Terraform state. bootstrap_state.sh creates it and
# `terraform init -backend-config="bucket=..."` points at it, so the name is derived once.
state_bucket() {
  printf '%s-igniteiq-tfstate' "$1"
}
