#!/usr/bin/env bash
# Creates the customer-owned Terraform state bucket (D3). Must run before `terraform init`
# (Cloud Shell state is ephemeral). It does not touch backend.tf: the bucket is handed to
# `terraform init -backend-config`, which scripts/deploy.sh does.
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

# Enforce the pre-flight checks here too, so a skipped Step 2 can't lead to a
# half-provisioned run. IGNITEIQ_DEPLOY_MODE is inherited by the child, and is
# named explicitly so it is obvious that this gate honours the same two modes:
# white-glove skips only the organization check (see preflight.sh for why).
IGNITEIQ_DEPLOY_MODE="${IGNITEIQ_DEPLOY_MODE:-self-serve}" \
  bash "$(dirname "$0")/preflight.sh"

PROJECT_ID="$(tfvars_get project_id)"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "[state] could not read project_id from terraform.tfvars" >&2
  exit 1
fi
REGION="$(tfvars_get region)"
REGION="${REGION:-us-central1}"
BUCKET="$(state_bucket "${PROJECT_ID}")"

# Fresh projects don't have the Cloud Storage API enabled — turn it on first, or
# the bucket create below fails. (Harmless if already enabled.)
echo "[state] ensuring the Cloud Storage API is enabled on ${PROJECT_ID}"
gcloud services enable storage.googleapis.com --project="${PROJECT_ID}"

# Create the bucket — but surface real errors instead of hiding them behind a
# misleading "already exists". We only skip creation when it genuinely exists.
if gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[state] bucket gs://${BUCKET} already exists"
else
  echo "[state] creating gs://${BUCKET}"
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT_ID}" --location="${REGION}" --uniform-bucket-level-access \
    --public-access-prevention
fi

# 🔴 Object versioning, and applied on EVERY run rather than only on create.
#
# This holds the only record of what Terraform believes exists. A truncated write, a
# half-finished apply or a `terraform state rm` against the wrong address is recoverable
# from a previous generation and is not recoverable without one. Terraform locks against
# concurrent writes; it does not keep history.
#
# Unconditional because buckets made before this line exist and are unversioned — one
# tenant's was created by hand on 2026-10-22 and needed versioning switched on afterwards. Running
# it every time is idempotent and repairs those in passing, which a create-only flag
# would not.
# Public-access prevention rides the same every-run update, for the same reason: state
# holds generated passwords, and a bucket made before this line was created without it.
echo "[state] ensuring object versioning and public-access prevention on gs://${BUCKET}"
gcloud storage buckets update "gs://${BUCKET}" --versioning --public-access-prevention --project="${PROJECT_ID}"

echo "[state] gs://${BUCKET} is ready. Next: bash scripts/ensure_terraform.sh && terraform init -backend-config=\"bucket=${BUCKET}\""
