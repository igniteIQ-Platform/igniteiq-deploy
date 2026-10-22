# The datasets the pipeline reads/writes. Created before any sync or transform.

resource "google_bigquery_dataset" "datasets" {
  for_each   = toset(local.bq_datasets)
  project    = var.project_id
  dataset_id = each.value
  location   = var.region == "us-central1" ? "US" : var.region
  labels     = local.labels

  # 🔴 R4. The warehouse. Today its only protection is that BigQuery refuses to drop a dataset
  # holding tables unless told to -- which a `terraform destroy` is perfectly willing to tell it.
  # tapps alone carries 481,843 raw rows and 716,293 ontology rows, none of it reconstructable
  # without a re-pull. prevent_destroy cannot be lifted by a variable: removing protection is a
  # commit, reviewed like any other.
  lifecycle {
    prevent_destroy = true
  }

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

  # 🔴 R4, as above. Empty today on every tenant, and the engine's landing zone from the first
  # sync onward.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.enabled]
}
