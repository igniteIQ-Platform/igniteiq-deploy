#!/usr/bin/env bash
# Creates the customer-owned Terraform state bucket (D3) and points backend.tf
# at it. Must run before `terraform init` (Cloud Shell state is ephemeral).
set -euo pipefail

PROJECT_ID="$(grep -E '^\s*project_id' terraform.tfvars | sed -E 's/.*=\s*"([^"]+)".*/\1/')"
REGION="$(grep -E '^\s*region' terraform.tfvars | sed -E 's/.*=\s*"([^"]+)".*/\1/' || echo us-central1)"
BUCKET="${PROJECT_ID}-igniteiq-tfstate"

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
    --project="${PROJECT_ID}" --location="${REGION}" --uniform-bucket-level-access
fi

cat > backend.tf <<HCL
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "depot"
  }
}
HCL

echo "[state] backend.tf points at gs://${BUCKET}. Next: bash scripts/ensure_terraform.sh && terraform init"
