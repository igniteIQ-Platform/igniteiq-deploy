# shellcheck shell=bash
# Sourced by the bootstrap scripts, not run. Defines provisioning_token, which prints the
# short-lived token that authorizes the IgniteIQ callbacks.
#
# Terraform does not hand the token to the scripts. A sensitive value in a provisioner's
# environment makes Terraform suppress ALL of that script's output, so a failed apply shows
# "(output suppressed due to sensitive value in config)" and no error. The scripts read the
# token from the tfvars file instead, and their output stays visible.
#
# Sources, in order:
#   1. PROVISIONING_TOKEN, when the calling shell exports it. For a run whose variables do
#      not come from terraform.tfvars (-var-file, TF_VAR_...).
#   2. The provisioning_token line of TFVARS_FILE (default: ./terraform.tfvars).
#
# Never echo the token: script output is no longer hidden.

provisioning_token() {
  if [[ -n "${PROVISIONING_TOKEN:-}" ]]; then
    printf '%s' "${PROVISIONING_TOKEN}"
    return 0
  fi

  local file="${TFVARS_FILE:-terraform.tfvars}" token
  if [[ ! -f "${file}" ]]; then
    echo "[provisioning-token] ${file} not found. Run: bash scripts/fetch_config.sh <code>, or export PROVISIONING_TOKEN." >&2
    return 1
  fi

  # Character classes, not \s: this runs in the customer's shell (see AGENTS.md).
  token="$(sed -nE 's/^[[:space:]]*provisioning_token[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "${file}" | head -n 1)"
  if [[ -z "${token}" ]]; then
    echo "[provisioning-token] no provisioning_token in ${file}. Regenerate the config in the Studio wizard, or export PROVISIONING_TOKEN." >&2
    return 1
  fi
  printf '%s' "${token}"
}
