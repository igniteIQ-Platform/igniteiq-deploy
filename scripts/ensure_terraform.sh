#!/usr/bin/env bash
# Ensure a usable Terraform is available before `terraform init`.
#
# Cloud Shell does not reliably ship Terraform, so this installs a pinned static binary
# straight into /usr/local/bin (on PATH, no apt repo / gpg dance, which proved flaky in
# Cloud Shell). The download is checked against a sha256 committed here, so what runs as
# Owner in the customer's project is the release we reviewed, not whatever the URL serves.
#
# Idempotent: a no-op when a new-enough terraform is already present. An older one is an
# error rather than a silent replacement, because a second binary on PATH is not reliably
# the one that runs.
set -euo pipefail

# Lowest version the module accepts: keep in step with required_version in versions.tf.
TF_MIN_VERSION="1.5.0"
# The release installed when none is present.
TF_VERSION="${TF_VERSION:-1.9.8}"

if command -v terraform >/dev/null 2>&1; then
  have="$(terraform version 2>/dev/null | sed -nE '1s/^Terraform v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' || true)"
  if [[ -z "${have}" ]]; then
    echo "[terraform] found $(command -v terraform) but could not read its version; remove it or fix it, then re-run." >&2
    exit 1
  fi
  if [[ "$(printf '%s\n%s\n' "${TF_MIN_VERSION}" "${have}" | sort -V | head -n 1)" != "${TF_MIN_VERSION}" ]]; then
    echo "[terraform] found v${have} at $(command -v terraform), but this module needs >= ${TF_MIN_VERSION}." >&2
    echo "[terraform] Remove or upgrade it, then re-run; this script installs v${TF_VERSION} when none is present." >&2
    exit 1
  fi
  echo "[terraform] already installed: v${have}"
  exit 0
fi

# Only the Linux release is pinned below: this installer is for Cloud Shell.
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "[terraform] not found, and this script only installs it on Linux (Cloud Shell). Install Terraform >= ${TF_MIN_VERSION} yourself: https://developer.hashicorp.com/terraform/install" >&2
  exit 1
fi

# Map uname -> HashiCorp release arch
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "[terraform] unsupported arch $(uname -m); install manually from https://developer.hashicorp.com/terraform/install" >&2; exit 1 ;;
esac

# sha256 of each zip, copied from terraform_<version>_SHA256SUMS on releases.hashicorp.com.
# Bumping TF_VERSION above means replacing both lines.
case "${TF_VERSION}_${ARCH}" in
  1.9.8_amd64) TF_SHA256="186e0145f5e5f2eb97cbd785bc78f21bae4ef15119349f6ad4fa535b83b10df8" ;;
  1.9.8_arm64) TF_SHA256="f85868798834558239f6148834884008f2722548f84034c9b0f62934b2d73ebb" ;;
  *)
    if [[ -z "${TF_SHA256:-}" ]]; then
      echo "[terraform] no checksum is pinned for v${TF_VERSION} (${ARCH}). Set TF_SHA256 to the zip's sha256, or unset TF_VERSION." >&2
      exit 1
    fi
    ;;
esac

ZIP="terraform_${TF_VERSION}_linux_${ARCH}.zip"
URL="https://releases.hashicorp.com/terraform/${TF_VERSION}/${ZIP}"

echo "[terraform] not found — installing v${TF_VERSION} (${ARCH}) from ${URL}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
curl -fsSL "${URL}" -o "${TMP}/tf.zip"
if ! echo "${TF_SHA256}  ${TMP}/tf.zip" | sha256sum -c - >/dev/null 2>&1; then
  echo "[terraform] checksum mismatch for ${ZIP}: refusing to install it. Re-run; if it repeats, contact IgniteIQ." >&2
  exit 1
fi
unzip -o -q "${TMP}/tf.zip" -d "${TMP}"
sudo install -m 0755 "${TMP}/terraform" /usr/local/bin/terraform

echo "[terraform] installed: $(terraform version | head -1)"
