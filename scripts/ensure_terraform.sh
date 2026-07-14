#!/usr/bin/env bash
# Ensure Terraform is available before `terraform init`.
#
# Google Cloud Shell has historically bundled Terraform, but some environments
# (personal-account shells, minimal/updated images) don't — the first real
# customer run hit exactly this. We install a pinned static binary straight into
# /usr/local/bin (on PATH, no apt repo / gpg dance, which proved flaky in Cloud
# Shell). Idempotent: no-op if a compatible terraform is already present.
set -euo pipefail

# Module requires >= 1.5 (versions.tf). Pin a known-good release.
TF_VERSION="${TF_VERSION:-1.9.8}"

if command -v terraform >/dev/null 2>&1; then
  echo "[terraform] already installed: $(terraform version | head -1)"
  exit 0
fi

# Map uname -> HashiCorp release arch
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "[terraform] unsupported arch $(uname -m); install manually from https://developer.hashicorp.com/terraform/install" >&2; exit 1 ;;
esac

ZIP="terraform_${TF_VERSION}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VERSION}/${ZIP}"

echo "[terraform] not found — installing v${TF_VERSION} (${ARCH}) from ${URL}"
TMP="$(mktemp -d)"
curl -fsSL "${URL}" -o "${TMP}/tf.zip"
unzip -o -q "${TMP}/tf.zip" -d "${TMP}"
sudo mv "${TMP}/terraform" /usr/local/bin/terraform
rm -rf "${TMP}"

echo "[terraform] installed: $(terraform version | head -1)"
