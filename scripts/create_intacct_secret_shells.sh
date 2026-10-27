#!/usr/bin/env bash
# Create the empty Sage Intacct credential secrets that Studio's "Connect Sage
# Intacct" writes into — for a project that was set up by hand and is NOT managed
# by this Terraform. (If it is, set `intacct_enabled = true` and apply instead.)
#
# Run it yourself, in your own Cloud Shell, as an account that can create secrets
# and set their IAM policy in the project (for example Secret Manager Admin):
#
#   bash scripts/create_intacct_secret_shells.sh <project-id> <slug> <depot-sa-email>
#   bash scripts/create_intacct_secret_shells.sh <project-id> acme depot-sa@<project-id>.iam.gserviceaccount.com
#
# What it does, per secret `<slug>-intacct-<field>`:
#   - creates the secret, EMPTY (no version), if it does not exist yet
#   - grants roles/secretmanager.secretAccessor on it to the depot service account,
#     which reads the values at sync time
# What it never does: delete or overwrite a secret, add or read a version, or grant
# anything to anyone else. Safe to re-run; it only fills in what is missing.
#
# The field list must match local.intacct_secret_fields in locals.tf; the parity
# check's self-test fails if the two drift.
set -euo pipefail

FIELDS=(sender-id sender-password company-id ws-user-id ws-user-password entity-id)
ACCESSOR_ROLE="roles/secretmanager.secretAccessor"

log() { echo "[intacct-secrets] $*"; }
die() { echo "[intacct-secrets] ERROR: $*" >&2; exit 1; }

if [[ $# -ne 3 ]]; then
  echo "usage: bash scripts/create_intacct_secret_shells.sh <project-id> <slug> <depot-sa-email>" >&2
  exit 2
fi

PROJECT_ID="$1"
SLUG="$2"
DEPOT_SA="$3"

[[ "${PROJECT_ID}" =~ ^[a-z][a-z0-9.:-]{4,61}[a-z0-9]$ ]] \
  || die "'${PROJECT_ID}' does not look like a GCP project id"
[[ "${SLUG}" =~ ^[a-z][a-z0-9-]{1,30}$ ]] \
  || die "slug must be lowercase letters, digits and hyphens, start with a letter, 2-31 characters; got '${SLUG}'"
[[ "${DEPOT_SA}" =~ ^[a-z0-9-]+@[a-z0-9.:-]+\.gserviceaccount\.com$ ]] \
  || die "'${DEPOT_SA}' does not look like a service account email (name@<project-id>.iam.gserviceaccount.com)"
MEMBER="serviceAccount:${DEPOT_SA}"

command -v gcloud >/dev/null 2>&1 || die "gcloud not found — run this in Cloud Shell"

log "project:         ${PROJECT_ID}"
log "slug:            ${SLUG}"
log "depot SA:        ${DEPOT_SA}"
log "running as:      $(gcloud config get-value account 2>/dev/null || echo unknown)"

# Stop before creating anything if the SA does not exist: a typo would otherwise
# leave shells that nothing can read. An account that may not view service accounts
# can still create secrets, so a denied lookup only warns.
if ! err="$(gcloud iam service-accounts describe "${DEPOT_SA}" --project="${PROJECT_ID}" \
    --format='value(email)' --quiet 2>&1 >/dev/null)"; then
  if grep -q 'NOT_FOUND' <<<"${err}"; then
    die "service account ${DEPOT_SA} does not exist in ${PROJECT_ID}"
  fi
  log "WARNING: could not look up ${DEPOT_SA} ($(grep -m1 '^ERROR:' <<<"${err}" || echo "${err}")); continuing"
fi

created=0
existed=0
granted=0
already_granted=0

for field in "${FIELDS[@]}"; do
  secret="${SLUG}-intacct-${field}"

  # A secret that cannot be read is NOT a missing secret: only NOT_FOUND leads to create.
  if err="$(gcloud secrets describe "${secret}" --project="${PROJECT_ID}" \
      --format='value(name)' --quiet 2>&1 >/dev/null)"; then
    log "exists:          ${secret} (left as is)"
    existed=$((existed + 1))
  elif grep -q 'NOT_FOUND' <<<"${err}"; then
    log "creating:        ${secret} (empty, automatic replication)"
    gcloud secrets create "${secret}" --project="${PROJECT_ID}" \
      --replication-policy=automatic --quiet >/dev/null
    created=$((created + 1))
  else
    die "cannot read ${secret}: $(grep -m1 '^ERROR:' <<<"${err}" || echo "${err}")"
  fi

  have="$(gcloud secrets get-iam-policy "${secret}" --project="${PROJECT_ID}" --quiet \
    --flatten='bindings[].members' --format='csv[no-heading](bindings.role,bindings.members)')"
  if grep -qxF "${ACCESSOR_ROLE},${MEMBER}" <<<"${have}"; then
    log "already granted: ${ACCESSOR_ROLE} on ${secret} to ${DEPOT_SA}"
    already_granted=$((already_granted + 1))
  else
    log "granting:        ${ACCESSOR_ROLE} on ${secret} to ${DEPOT_SA}"
    # add-iam-policy-binding adds one member to one role and leaves every other binding alone.
    gcloud secrets add-iam-policy-binding "${secret}" --project="${PROJECT_ID}" \
      --member="${MEMBER}" --role="${ACCESSOR_ROLE}" --condition=None --quiet >/dev/null
    granted=$((granted + 1))
  fi
done

echo
log "summary for ${PROJECT_ID}:"
log "  secrets created:          ${created}"
log "  secrets already present:  ${existed}"
log "  accessor grants added:    ${granted}"
log "  accessor grants present:  ${already_granted}"
log "done — no secret values were written. Connect Sage Intacct in Studio to fill them in."
