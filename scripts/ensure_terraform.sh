#!/usr/bin/env bash
# Ensure Terraform is available before `terraform init`.
#
# Google Cloud Shell has historically bundled Terraform, but some environments
# (personal-account shells, minimal/updated images) don't — the first real
# customer run hit exactly this. This checks for it and installs from the
# official HashiCorp apt repo if missing. Idempotent: safe to run repeatedly.
set -euo pipefail

if command -v terraform >/dev/null 2>&1; then
  echo "[terraform] already installed: $(terraform version | head -1)"
  exit 0
fi

echo "[terraform] not found — installing from the HashiCorp apt repo..."

# GPG key (--yes so a re-run doesn't fail on an existing keyring)
wget -qO - https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

CODENAME="$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release 2>/dev/null || lsb_release -cs)"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

sudo apt-get update -qq
sudo apt-get install -y terraform

echo "[terraform] installed: $(terraform version | head -1)"
