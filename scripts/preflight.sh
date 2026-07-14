#!/usr/bin/env bash
# Pre-flight checks — catch the #1 blocker (no Google Cloud Organization) BEFORE
# you spend 15-20 min on `terraform apply`. Runs as you, in your own Cloud Shell,
# so it can see your project (IgniteIQ never can). Reads project_id from the
# terraform.tfvars that scripts/fetch_config.sh wrote.
set -euo pipefail

if [[ ! -f terraform.tfvars ]]; then
  echo "[preflight] no terraform.tfvars yet — run: bash scripts/fetch_config.sh <code>" >&2
  exit 1
fi

PROJECT_ID="$(grep -E '^\s*project_id' terraform.tfvars | sed -E 's/.*=\s*"([^"]+)".*/\1/')"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "[preflight] could not read project_id from terraform.tfvars" >&2
  exit 1
fi
echo "[preflight] project: ${PROJECT_ID}"

# 1) ORGANIZATION — the deploy needs an org-backed project. get-ancestors walks
#    project -> (folders) -> org, so this is correct even for folder-nested
#    projects. A standalone personal-@gmail.com project has no org in its ancestry.
ANCESTORS="$(gcloud projects get-ancestors "${PROJECT_ID}" --format='value(type)' 2>/dev/null || true)"
if ! grep -q '^organization$' <<<"${ANCESTORS}"; then
  cat >&2 <<EOF

  ✗ This project is NOT under a Google Cloud Organization.

    IgniteIQ's deploy provisions GKE, Cloud SQL, Workload Identity and service
    accounts — none of which work in a standalone project owned by a personal
    \`@gmail.com\` account (Google blocks the admin operations).

    Fix:
      1. Give your business a Google Cloud Organization — free via Cloud Identity
         (identity-only; it does NOT touch your existing email):
         https://cloud.google.com/identity/docs/set-up-cloud-identity-admin
      2. Create the project UNDER that org, enable billing.
      3. Re-run Cloud Shell signed in as an organization account
         (you@yourcompany.com), not a personal Gmail.

EOF
  exit 1
fi
echo "[preflight] ✓ project is under a Google Cloud Organization"

# 2) BILLING — required for GKE/SQL. Warn (don't hard-fail) if we can't confirm.
BILLING="$(gcloud billing projects describe "${PROJECT_ID}" --format='value(billingEnabled)' 2>/dev/null || echo "")"
if [[ "${BILLING}" == "True" ]]; then
  echo "[preflight] ✓ billing is enabled"
else
  echo "[preflight] ⚠ could not confirm billing is enabled on ${PROJECT_ID} — make sure it is before you continue." >&2
fi

echo "[preflight] checks passed — continue: bash scripts/bootstrap_state.sh"
