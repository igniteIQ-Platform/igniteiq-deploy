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
# MUST wait for the cluster — the `<project>.svc.id.goog` identity pool that
# local.wi_member references only comes into existence once a Workload-Identity
# cluster is created (ordering trap surfaced in the first sandbox apply, ENG-258).
resource "google_service_account_iam_member" "depot_wi" {
  service_account_id = google_service_account.depot.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wi_member

  depends_on = [google_container_cluster.depot]
}

# ── IgniteIQ data-plane grants (Forge transforms, Vault queries) ─────────────
# Least-privilege, dataset-scoped where possible. These are the ONLY standing
# IgniteIQ identities in the project (plus the write-only secret path below).

resource "google_project_iam_member" "forge_job_user" {
  for_each = var.igniteiq_forge_sas
  project  = var.project_id
  role     = "roles/bigquery.jobUser"
  member   = "serviceAccount:${each.value}"
}

# Project-level dataEditor (matches the established tenants, e.g. tapps-data).
# dbt CREATES output datasets on the fly — the staging/intermediate/ontology
# models plus elementary's monitoring dataset (`armory_monitor`) — which needs
# bigquery.datasets.create. Dataset-scoped grants can't do that, so the forge
# run failed on the first customer with "does not have datasets.create". This
# covers reading depot_raw + writing forge_*/ontology + creating what dbt needs.
#
# 🔴 DO NOT narrow this to a dataset-scoped grant on `ontology`. It has been
# proposed once per environment and it cannot work, for two independent reasons:
# dbt writes forge_staging AND forge_intermediate as well as ontology, and it
# CREATES `dbt_test__audit` + elementary's `armory_monitor`, neither of which is
# in local.bq_datasets (both exist on redwood today — proof dbt made them). The
# architecture doc adjudicates this explicitly and calls the width deliberate:
# docs/architecture/tenant-iam-and-policy-matrix.html, "Target state" →
# forge-runner → "Dataset-scoped grants cannot express that."
resource "google_project_iam_member" "forge_data_editor" {
  for_each = var.igniteiq_forge_sas
  project  = var.project_id
  role     = "roles/bigquery.dataEditor"
  member   = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "vault_job_user" {
  for_each = var.igniteiq_vault_sas
  project  = var.project_id
  role     = "roles/bigquery.jobUser"
  member   = "serviceAccount:${each.value}"
}

# Vault is the opposite case and stays dataset-scoped: a query engine reads the
# published marts and nothing else. Project-level dataViewer here is the ENG-437
# regression — held that way on tapps/reynolds/eco, correct on jolly, which is
# the tenant this module built.
resource "google_bigquery_dataset_iam_member" "vault_ontology_viewer" {
  for_each   = var.igniteiq_vault_sas
  project    = var.project_id
  dataset_id = google_bigquery_dataset.datasets["ontology"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${each.value}"
}

# ── address moves: single resource -> for_each instance ──────────────────────
# Each live tenant's state (in the CUSTOMER's own GCS bucket) holds the
# un-indexed addresses. Without these, the next `terraform apply` DESTROYS and
# recreates each binding — a momentary revoke on a live Vault and a live Forge,
# on a project whose dashboards are customer-facing. `moved` re-keys in state
# with no API call. Safe to delete once every tenant has applied once.
moved {
  from = google_project_iam_member.forge_job_user
  to   = google_project_iam_member.forge_job_user["forge-runner@igniteiq-core.iam.gserviceaccount.com"]
}

moved {
  from = google_project_iam_member.forge_data_editor
  to   = google_project_iam_member.forge_data_editor["forge-runner@igniteiq-core.iam.gserviceaccount.com"]
}

moved {
  from = google_project_iam_member.vault_job_user
  to   = google_project_iam_member.vault_job_user["vault-sa@igniteiq-dev.iam.gserviceaccount.com"]
}

moved {
  from = google_bigquery_dataset_iam_member.vault_ontology_viewer
  to   = google_bigquery_dataset_iam_member.vault_ontology_viewer["vault-sa@igniteiq-dev.iam.gserviceaccount.com"]
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

# The Platform / Studio API reads the customer's BigQuery to power the Data
# explorer pages (Raw / Models / Marts / Dictionary). READ-ONLY, matching the
# established tenants (tapps-data). metadataViewer lets it list tables/lineage
# without reading rows; dataViewer + jobUser let it run the listing queries.
# Without these the Studio "Raw Tables" page 403s ("no bigquery.jobs.create").
resource "google_project_iam_member" "platform_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${var.igniteiq_platform_sa}"
}
resource "google_project_iam_member" "platform_bq_data_viewer" {
  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${var.igniteiq_platform_sa}"
}
resource "google_project_iam_member" "platform_bq_metadata_viewer" {
  project = var.project_id
  role    = "roles/bigquery.metadataViewer"
  member  = "serviceAccount:${var.igniteiq_platform_sa}"
}
