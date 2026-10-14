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
# in local.bq_datasets — observed present on an existing project, which is proof
# dbt created them. The architecture doc adjudicates this and calls the width
# deliberate: docs/architecture/tenant-iam-and-policy-matrix.html, "Target
# state" → forge-runner → "Dataset-scoped grants cannot express that."
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
# regression — several older projects hold it that way; the projects this module
# provisioned are correctly dataset-scoped.
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

# ── Depot v2, ENG-1021. Everything below is additive and OFF unless
# depot_v2_enabled = true; with it false an apply on a live tenant changes nothing. Names carry
# `depot-v2` so they collide with nothing of the running Depot's.

# ── Identity: the existing depot-sa ──────────────────────────────────────────
# No new service account. Every component runs as one Kubernetes ServiceAccount,
# bound to depot-sa, which already holds bigquery.jobUser and dataEditor. What it
# gains is below: the secret roles and this binding. The ingestion runtime and the
# relay already run as depot-sa, so they gain the same.
# Same ordering trap as iam.tf: the identity pool exists only once the cluster does.
resource "google_service_account_iam_member" "depot_v2_wi" {
  count              = local.v2
  service_account_id = google_service_account.depot.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.v2_namespace}/${local.v2_ksa}]"

  depends_on = [google_container_cluster.depot]
}

# The operator runs as the same depot-sa (decision 0045, option C) from its own namespace:
# it polls the IgniteIQ platform with depot-sa's identity token and pulls the engine chart
# with depot-sa's access token. Its own, narrower account is a 0045 follow-up.
resource "google_service_account_iam_member" "depot_operator_wi" {
  count              = local.operator
  service_account_id = google_service_account.depot.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.operator_namespace}/${local.operator_ksa}]"

  depends_on = [google_container_cluster.depot]
}

# `helm pull` of the engine chart, as depot-sa. The node identity reads images at pull time
# (artifactregistry.tf node_reader); the chart is read by the operator itself.
resource "google_artifact_registry_repository_iam_member" "depot_operator_chart_reader" {
  count      = local.operator
  project    = var.project_id
  location   = google_artifact_registry_repository.depot_connectors.location
  repository = google_artifact_registry_repository.depot_connectors.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.depot.email}"
}

# ── Secret Manager: two custom roles on depot-sa ─────────────────────────────
# The engine stores each connection's credentials itself: get, create, add a
# version, access, delete. Nothing predefined short of secretmanager.admin can
# CREATE a secret, and admin reads every secret in the project. Two roles because
# of how conditions bind:
#   - create is checked against the PROJECT (the secret does not exist yet), so a
#     name condition would deny it; it gets an unconditional, create-only role.
#   - get/delete/add/access are checked against the SECRET, so they are granted
#     under a condition on the prefix and reach nothing else in the project.
# ❓ Unverified end to end.

resource "google_project_iam_custom_role" "depot_v2_secret_creator" {
  count       = local.v2
  project     = var.project_id
  role_id     = "depotV2SecretCreator"
  title       = "Depot v2 — create secrets"
  permissions = ["secretmanager.secrets.create"]
}

resource "google_project_iam_custom_role" "depot_v2_secret_owner" {
  count   = local.v2
  project = var.project_id
  role_id = "depotV2SecretOwner"
  title   = "Depot v2 — manage its own secrets"
  permissions = [
    "secretmanager.secrets.get",
    "secretmanager.secrets.delete",
    "secretmanager.versions.add",
    "secretmanager.versions.access",
  ]
}

resource "google_project_iam_member" "depot_v2_secret_creator" {
  count   = local.v2
  project = var.project_id
  role    = google_project_iam_custom_role.depot_v2_secret_creator[0].id
  member  = "serviceAccount:${google_service_account.depot.email}"
}

resource "google_project_iam_member" "depot_v2_secret_owner" {
  count   = local.v2
  project = var.project_id
  role    = google_project_iam_custom_role.depot_v2_secret_owner[0].id
  member  = "serviceAccount:${google_service_account.depot.email}"
  condition {
    title      = "depot-v2 secrets only"
    expression = local.v2_secret_condition
  }
}
