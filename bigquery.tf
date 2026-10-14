# The datasets the pipeline reads/writes. Created before any sync or transform.

resource "google_bigquery_dataset" "datasets" {
  for_each   = toset(local.bq_datasets)
  project    = var.project_id
  dataset_id = each.value
  location   = var.region == "us-central1" ? "US" : var.region
  labels     = local.labels

  depends_on = [google_project_service.enabled]
}

# ── Depot v2, ENG-1021. Everything below is additive and OFF unless
# depot_v2_enabled = true; with it false an apply on a live tenant changes nothing. Names carry
# `depot-v2` so they collide with nothing of the running Depot's.

# ── Raw dataset ──────────────────────────────────────────────────────────────
# Created here, not by the sink: a dataset the worker creates has no declared
# location, is owned by the worker, and cannot be deleted by a project Editor.
resource "google_bigquery_dataset" "depot_raw_v2" {
  count      = local.v2
  project    = var.project_id
  dataset_id = "depot_raw_v2"
  location   = var.region == "us-central1" ? "US" : var.region
  labels     = local.labels

  depends_on = [google_project_service.enabled]
}
