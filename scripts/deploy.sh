#!/usr/bin/env bash
# Deploy the IgniteIQ Depot stack into your own GCP project, in one command.
#
#   bash scripts/deploy.sh <one-time-code>
#   bash scripts/deploy.sh                      # re-run after a failure
#   bash scripts/deploy.sh --auto-approve ...   # skip Terraform's "yes" prompt
#
# Runs the steps below in order and stops at the first one that fails. It is safe to run
# again: every step either checks before it acts or is idempotent, and the settings fetched
# the first time are kept. IGNITEIQ_DEPLOY_MODE is passed through to the pre-flight checks
# (see preflight.sh).
#
#   1. tools        the commands the deploy needs are installed
#   2. settings     terraform.tfvars, fetched with the one-time code
#   3. pre-flight   organization, billing, sharing policy, network
#   4. state        the bucket that holds Terraform state, in your project
#   5. terraform    installed if missing
#   6. init         against that bucket
#   7. apply        15-20 minutes
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/common.sh
source scripts/common.sh

log() { echo "[deploy] $*"; }
die() { echo "[deploy] $*" >&2; exit 1; }

AUTO_APPROVE=0
CODE=""
for arg in "$@"; do
  case "${arg}" in
    --auto-approve) AUTO_APPROVE=1 ;;
    -h|--help) sed -n '2,7p' scripts/deploy.sh | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option ${arg}. Usage: bash scripts/deploy.sh [--auto-approve] [<one-time-code>]" ;;
    *)
      [[ -z "${CODE}" ]] || die "expected one code, got two ('${CODE}' and '${arg}')."
      CODE="${arg}"
      ;;
  esac
done

# ── 1. tools ─────────────────────────────────────────────────────────────────
# All of them, up front: kubectl, helm and python3 are not needed until the bootstrap, which
# is 15 minutes into the apply and a poor place to discover one is missing.
missing=()
for tool in gcloud kubectl helm python3 curl unzip; do
  command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if [[ "${#missing[@]}" -gt 0 ]]; then
  die "missing required tool(s): ${missing[*]}. Google Cloud Shell has them all; run this there, or install them."
fi

# ── 2. settings ──────────────────────────────────────────────────────────────
# The code is single-use, so IgniteIQ refuses it the second time. A re-run with the SAME
# code is recognized here instead, by a hash of the code kept beside the settings it fetched,
# and does not fetch again. A DIFFERENT code must fetch successfully, and replaces the
# settings: that is how an expired provisioning token is refreshed.
#
# A failed fetch never falls back to whatever terraform.tfvars happens to be here. In a
# checkout used for more than one project, that would apply to the wrong one.
CODE_MARK="terraform.tfvars.code-sha256" # ignored by git, like terraform.tfvars.*
code_hash() { printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }
if [[ -n "${CODE}" ]]; then
  want="$(code_hash "${CODE}")"
  if [[ -f terraform.tfvars && -f "${CODE_MARK}" && "$(cat "${CODE_MARK}")" == "${want}" ]]; then
    log "the settings for this code are already here; not fetching them again"
  else
    bash scripts/fetch_config.sh "${CODE}" \
      || die "could not fetch your settings with that code, so nothing was changed. Check the code, or get a new one from the Studio wizard."
    printf '%s\n' "${want}" > "${CODE_MARK}"
  fi
elif [[ ! -f terraform.tfvars ]]; then
  die "no settings yet. Run: bash scripts/deploy.sh <one-time-code from the Studio wizard>"
else
  log "using the settings fetched earlier (terraform.tfvars)"
fi

PROJECT_ID="$(tfvars_get project_id)"
[[ -n "${PROJECT_ID}" ]] || die "could not read project_id from terraform.tfvars"

# ── 3 + 4. pre-flight, then the state bucket ─────────────────────────────────
# bootstrap_state.sh runs preflight.sh itself, so a skipped check can never precede a write.
bash scripts/bootstrap_state.sh

# ── 5. terraform ─────────────────────────────────────────────────────────────
bash scripts/ensure_terraform.sh

# ── 6. init ──────────────────────────────────────────────────────────────────
# State written to this directory by a `terraform init` that named no bucket is NOT copied
# by the init below. Applying past it would plan to create everything a second time.
if [[ -s terraform.tfstate ]]; then
  die "found local Terraform state (terraform.tfstate) in this directory. It has to be moved into gs://$(state_bucket "${PROJECT_ID}") before deploying; contact IgniteIQ."
fi
# -reconfigure: take the bucket from this command and ignore any backend an earlier init
# saved in .terraform/. It never copies state, which is the point: a checkout that was last
# used for another project must not offer to migrate that project's state into this one.
log "initializing Terraform against gs://$(state_bucket "${PROJECT_ID}")"
terraform init -input=false -reconfigure -backend-config="bucket=$(state_bucket "${PROJECT_ID}")"

# ── 7. apply ─────────────────────────────────────────────────────────────────
if [[ "${AUTO_APPROVE}" == "1" ]]; then
  terraform apply -input=false -auto-approve
else
  log "Terraform will list what it is about to create in ${PROJECT_ID} and ask you to type 'yes'."
  terraform apply
fi

log "done. Return to the IgniteIQ Studio tab: it detects completion and walks you through connecting your data."
