# ── Depot ingestion SA (in-project) — writes landed data to BigQuery ─────────
# GKE ingestion runs as this SA via Workload Identity. No cross-project reach-in
# identity exists: the sovereignty guarantee is that nothing writes this
# project's raw data from outside the project.

resource "google_service_account" "depot" {
  project      = var.project_id
  account_id   = "depot-sa"
  display_name = "Depot ingestion — BigQuery writer"
}

resource "google_project_iam_member" "depot_bq_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.depot.email}"
}

resource "google_project_iam_member" "depot_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.depot.email}"
}

# Workload Identity: the ingestion runtime's k8s SA impersonates depot-sa.
resource "google_service_account_iam_member" "depot_wi" {
  service_account_id = google_service_account.depot.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wi_member
}

# ── IgniteIQ data-plane grants (Forge transforms, Vault queries) ─────────────
# Least-privilege, dataset-scoped where possible. These are the ONLY standing
# IgniteIQ identities in the project (plus the write-only secret path below).

resource "google_project_iam_member" "forge_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${var.igniteiq_forge_sa}"
}

resource "google_bigquery_dataset_iam_member" "forge_editor" {
  for_each   = toset(["forge_staging", "forge_intermediate", "ontology"])
  project    = var.project_id
  dataset_id = google_bigquery_dataset.datasets[each.value].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${var.igniteiq_forge_sa}"
}

resource "google_bigquery_dataset_iam_member" "forge_raw_viewer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.datasets["depot_raw"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${var.igniteiq_forge_sa}"
}

resource "google_project_iam_member" "vault_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${var.igniteiq_vault_sa}"
}

resource "google_bigquery_dataset_iam_member" "vault_ontology_viewer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.datasets["ontology"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${var.igniteiq_vault_sa}"
}

# ── Write-only secret path (Studio credential vaulting) ──────────────────────
# The Platform SA can ADD versions to this project's secrets but can NEVER read
# a payload back, and cannot create secrets. This is how Studio's "Connect
# ServiceTitan" writes credentials into the customer's own Secret Manager.

resource "google_project_iam_member" "platform_secret_version_adder" {
  project = var.project_id
  role    = "roles/secretmanager.secretVersionAdder"
  member  = "serviceAccount:${var.igniteiq_platform_sa}"
}
