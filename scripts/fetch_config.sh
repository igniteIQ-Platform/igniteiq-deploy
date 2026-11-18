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
# Runs in the CUSTOMER's Cloud Shell, not in a tier, so the public entry point is the
# right default here; IGNITEIQ_API overrides it for internal testing.
BASE="${IGNITEIQ_API:-https://api.igniteiq.com}"  # bare-host-ok: customer-facing public endpoint

if [[ -z "${CODE}" ]]; then
  echo "usage: bash scripts/fetch_config.sh <one-time-code from the Studio wizard>" >&2
  exit 2
fi

# Downloaded beside the target and moved into place only on success. Writing straight to
# terraform.tfvars destroyed the settings from an earlier run whenever a used code was
# tried again, which is exactly what re-running the deploy does.
TMP="$(mktemp terraform.tfvars.XXXXXX)"
trap 'rm -f "${TMP}"' EXIT

echo "[fetch-config] retrieving terraform.tfvars from ${BASE} ..."
# curl's own status matters as much as the HTTP one: a connection cut mid-body still reports
# 200. Either failing leaves the settings already here untouched.
CURL_RC=0
HTTP="$(curl -s -o "${TMP}" -w "%{http_code}" --max-time 30 \
  "${BASE}/api/onboarding/config?code=${CODE}")" || CURL_RC=$?

if [[ "${CURL_RC}" != "0" && "${HTTP}" == "200" ]]; then
  echo "[fetch-config] FAILED: the download was cut short (curl exit ${CURL_RC}). Get a new code from the Studio wizard and try again." >&2
  exit 1
fi
if [[ "${HTTP}" != "200" ]]; then
  echo "[fetch-config] FAILED (HTTP ${HTTP}). The code may be expired or already used —" >&2
  echo "               regenerate it in the Studio onboarding wizard and try again." >&2
  exit 1
fi

if ! grep -qE '^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"[^"]+"' "${TMP}"; then
  echo "[fetch-config] FAILED: the response is not a usable terraform.tfvars (no project_id). Contact IgniteIQ." >&2
  exit 1
fi

mv "${TMP}" terraform.tfvars
echo "[fetch-config] wrote terraform.tfvars."
echo "[fetch-config] next: bash scripts/deploy.sh"
