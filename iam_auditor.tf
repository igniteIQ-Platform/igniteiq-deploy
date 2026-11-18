# ── Read-only posture auditor (ENG-433) ──────────────────────────────────────
# A custom role plus one binding, so every tenant is auditable from provision time.
#
# The gap this closes: a customer self-provisioned, and no identity we hold could read its IAM
# policy — so the one tenant we did not build by hand is the only one whose access
# configuration we cannot verify. That is the sovereignty model working as designed, not a
# defect, which is exactly why the fix belongs in the module rather than in a support runbook:
# the customer's own apply grants it, at the moment the project is created.
#
# Kept as a SEPARATE identity from every other grant in iam.tf on purpose. forge-runner and
# depot-sa hold write access to data; the deployer holds Owner during the build. An auditor
# that shares an identity with any of those cannot honestly be described to a customer as
# read-only, and "it cannot read your data" is the sentence that gets this approved.
#
# Permission rationale and the verification evidence live in
# roles/tenant_posture_auditor.yaml — including the tested claims (secret names 200, secret
# payload 403, data query 403) measured against a real project, and re-verified on the
# customer's own project when the customer granted it on 2026-08-05.

resource "google_project_iam_custom_role" "tenant_posture_auditor" {
  project     = var.project_id
  role_id     = "tenantPostureAuditor"
  title       = "Tenant posture auditor"
  description = "Read-only. Verifies that this project's access configuration still matches what IgniteIQ deployed. Cannot read project data, cannot read secret payloads, cannot modify anything."
  stage       = "GA"

  # Read from roles/tenant_posture_auditor.yaml, which is also the file `gcloud iam roles
  # create --file` takes to retrofit a live tenant by hand. One list, so the role this module
  # creates and the role applied by hand cannot drift apart. Each permission is explained there.
  permissions = yamldecode(file("${path.module}/roles/tenant_posture_auditor.yaml")).includedPermissions
}

resource "google_project_iam_member" "tenant_auditor" {
  project = var.project_id
  role    = google_project_iam_custom_role.tenant_posture_auditor.id
  member  = "serviceAccount:${var.igniteiq_auditor_sa}"
}
