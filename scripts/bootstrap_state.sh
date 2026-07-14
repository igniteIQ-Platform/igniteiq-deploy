#!/usr/bin/env bash
# Creates the customer-owned Terraform state bucket (D3) and points backend.tf
# at it. Must run before `terraform init` (Cloud Shell state is ephemeral).
set -euo pipefail

PROJECT_ID="$(grep -E '^\s*project_id' terraform.tfvars | sed -E 's/.*=\s*"([^"]+)".*/\1/')"
REGION="$(grep -E '^\s*region' terraform.tfvars | sed -E 's/.*=\s*"([^"]+)".*/\1/' || echo us-central1)"
BUCKET="${PROJECT_ID}-igniteiq-tfstate"

echo "[state] ensuring gs://${BUCKET}"
gcloud storage buckets create "gs://${BUCKET}" \
  --project="${PROJECT_ID}" --location="${REGION}" --uniform-bucket-level-access 2>/dev/null \
  || echo "[state] bucket already exists"

cat > backend.tf <<HCL
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "depot"
  }
}
HCL

echo "[state] backend.tf points at gs://${BUCKET}. Next: bash scripts/ensure_terraform.sh && terraform init"
