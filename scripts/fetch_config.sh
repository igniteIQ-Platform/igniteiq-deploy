#!/usr/bin/env bash
# Fetch this deployment's terraform.tfvars from IgniteIQ using the one-time code
# the Studio onboarding wizard showed you.
#
#   bash scripts/fetch_config.sh <code>
#
# Why a code (not a URL param): the tfvars carries the short-lived provisioning
# token, so it is delivered over HTTPS in exchange for a single-use code — never
# embedded in the Cloud Shell link (which would be logged/shareable). The code
# is short-lived + single-use; it authorizes exactly this one config fetch.
#
# Endpoint contract (served by the Platform / Studio wizard, ENG-257):
#   GET {IGNITEIQ_API}/api/onboarding/config?code=<code>
#     200 -> body is the terraform.tfvars content
#     401/404/410 -> code invalid / expired / already used
set -euo pipefail

CODE="${1:-}"
BASE="${IGNITEIQ_API:-https://api.igniteiq.com}"

if [[ -z "${CODE}" ]]; then
  echo "usage: bash scripts/fetch_config.sh <one-time-code from the Studio wizard>" >&2
  exit 2
fi

echo "[fetch-config] retrieving terraform.tfvars from ${BASE} ..."
HTTP=$(curl -s -o terraform.tfvars -w "%{http_code}" --max-time 30 \
  "${BASE}/api/onboarding/config?code=${CODE}" || echo "000")

if [[ "${HTTP}" != "200" ]]; then
  rm -f terraform.tfvars
  echo "[fetch-config] FAILED (HTTP ${HTTP}). The code may be expired or already used —" >&2
  echo "               regenerate it in the Studio onboarding wizard and try again." >&2
  exit 1
fi

echo "[fetch-config] wrote terraform.tfvars."
echo "[fetch-config] next: bash scripts/bootstrap_state.sh && bash scripts/ensure_terraform.sh && terraform init && terraform apply"
