#!/usr/bin/env bash
# Pre-flight checks — catch the blockers BEFORE you spend 15-20 min on
# `terraform apply`. Runs as you, in your own Cloud Shell, so it can see your
# project (IgniteIQ never can). Reads project_id from the terraform.tfvars that
# scripts/fetch_config.sh wrote.
#
# IGNITEIQ_DEPLOY_MODE=self-serve (default) | white-glove
#
# The organization check below applies ONLY to self-serve, because the thing it
# is really testing is the CALLER's identity, not the project's parent. Set
# white-glove when an IgniteIQ operator runs the deploy as a service account.
# The billing and domain-restricted-sharing checks apply to both modes and are
# never skipped.
set -euo pipefail

DEPLOY_MODE="${IGNITEIQ_DEPLOY_MODE:-self-serve}"
case "${DEPLOY_MODE}" in
  self-serve|white-glove) ;;
  *)
    echo "[preflight] IGNITEIQ_DEPLOY_MODE must be 'self-serve' or 'white-glove', got '${DEPLOY_MODE}'" >&2
    exit 1
    ;;
esac

if [[ ! -f terraform.tfvars ]]; then
  echo "[preflight] no terraform.tfvars yet — run: bash scripts/fetch_config.sh <code>" >&2
  exit 1
fi

PROJECT_ID="$(grep -E '^[[:space:]]*project_id' terraform.tfvars | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "[preflight] could not read project_id from terraform.tfvars" >&2
  exit 1
fi
echo "[preflight] project: ${PROJECT_ID}"

# 1) ORGANIZATION — SELF-SERVE ONLY. get-ancestors walks project -> (folders) ->
#    org, so this is correct even for folder-nested projects. A standalone
#    personal-@gmail.com project has no org in its ancestry.
#
#    🔴 What this check actually tests is the CALLER, not the project. The
#    failure it prevents is `Regional Access Boundary ... 'Gaia id not found for
#    email <user>@gmail.com'` — a caller with no directory entry cannot perform
#    admin writes. In self-serve the caller IS the customer, so a personal-Gmail
#    caller fails. In white-glove the caller is an IgniteIQ service account that
#    lives in an org-backed project and whose Gaia id resolves, so the target
#    project's parentage is irrelevant and an org-less project deploys fine.
#    Proven empirically on a white-glove deploy, 2026-07-28.
#
#    Treating this as universal has already cost a customer meeting: the project
#    was org-less, the deploy was white-glove, and we sent them to set up Cloud
#    Identity for a blocker that did not exist. Keep the two modes distinct.
ANCESTORS="$(gcloud projects get-ancestors "${PROJECT_ID}" --format='value(type)' 2>/dev/null || true)"
if grep -q '^organization$' <<<"${ANCESTORS}"; then
  echo "[preflight] ✓ project is under a Google Cloud Organization"
elif [[ "${DEPLOY_MODE}" == "white-glove" ]]; then
  cat <<EOF
[preflight] ⚠ project is NOT under a Google Cloud Organization — continuing
            because IGNITEIQ_DEPLOY_MODE=white-glove. The caller is an IgniteIQ
            service account in an org-backed project, so this is not a blocker.
            Two consequences worth knowing rather than discovering:
              • no org means no org policy, so domain-restricted sharing cannot
                be enforced here (check 3 below will confirm)
              • moving the project into an org later is free and preserves the
                project id, every IAM binding and every dataset — but re-verify
                afterwards, because it then inherits that org's policies
EOF
else
  cat >&2 <<EOF

  ✗ This project is NOT under a Google Cloud Organization.

    IgniteIQ's deploy provisions GKE, Cloud SQL, Workload Identity and service
    accounts. When you run the deploy yourself, Google blocks those admin
    operations for a caller with no directory entry — which is the case for a
    personal \`@gmail.com\` account.

    Fix:
      1. Give your business a Google Cloud Organization — free via Cloud Identity
         (identity-only; it does NOT touch your existing email):
         https://cloud.google.com/identity/docs/set-up-cloud-identity-admin
      2. Create the project UNDER that org, enable billing.
      3. Re-run Cloud Shell signed in as an organization account
         (you@yourcompany.com), not a personal Gmail.

    If an IgniteIQ operator is running this deploy for you, this is not a
    blocker — they will re-run with IGNITEIQ_DEPLOY_MODE=white-glove.

EOF
  exit 1
fi

# 2) BILLING — required for GKE/SQL. Warn (don't hard-fail) if we can't confirm.
BILLING="$(gcloud billing projects describe "${PROJECT_ID}" --format='value(billingEnabled)' 2>/dev/null || echo "")"
if [[ "${BILLING}" == "True" ]]; then
  echo "[preflight] ✓ billing is enabled"
else
  echo "[preflight] ⚠ could not confirm billing is enabled on ${PROJECT_ID} — make sure it is before you continue." >&2
fi

# 3) DOMAIN RESTRICTED SHARING — a Cloud Identity / Workspace org enables
#    iam.allowedPolicyMemberDomains by default (own customer-id only). The deploy
#    grants IAM to IgniteIQ service accounts, which that policy would reject
#    ("not in permitted organization") — so catch it here, not 5 min into apply.
IGNITEIQ_CUSTOMER_ID="C0178jm4f"
POLICY="$(gcloud org-policies describe iam.allowedPolicyMemberDomains --project="${PROJECT_ID}" --effective --format=json 2>/dev/null \
  || gcloud resource-manager org-policies describe iam.allowedPolicyMemberDomains --project="${PROJECT_ID}" --effective --format=json 2>/dev/null \
  || echo '{}')"
if grep -q "${IGNITEIQ_CUSTOMER_ID}" <<<"${POLICY}"; then
  echo "[preflight] ✓ domain-restricted sharing allowlists IgniteIQ (${IGNITEIQ_CUSTOMER_ID})"
elif grep -qE '"allowAll"[[:space:]]*:[[:space:]]*true|"allValues"[[:space:]]*:[[:space:]]*"ALLOW"' <<<"${POLICY}"; then
  echo "[preflight] ✓ domain-restricted sharing allows all (not restricted)"
elif grep -q 'allowedValues' <<<"${POLICY}"; then
  cat >&2 <<EOF

  ✗ Domain restricted sharing (iam.allowedPolicyMemberDomains) is enforced on this
    project and does NOT permit IgniteIQ. The deploy grants IAM to IgniteIQ service
    accounts, which will be rejected ("not in permitted organization").

    Fix — Console → IAM & Admin → Organization Policies → "Domain restricted
    sharing" → Manage policy on project ${PROJECT_ID}:
      • Override parent's policy → add a rule → "Merge with parent" → Allowed →
        add the value:  ${IGNITEIQ_CUSTOMER_ID}
      • (or set the rule to "Allow All" for this project)
    Save, wait ~1-2 min, then re-run.

EOF
  exit 1
else
  echo "[preflight] ✓ domain-restricted sharing not enforced"
fi

echo "[preflight] checks passed (mode: ${DEPLOY_MODE}) — continue: bash scripts/bootstrap_state.sh"
