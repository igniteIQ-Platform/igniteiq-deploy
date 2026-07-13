# The datasets the pipeline reads/writes. Created before any sync or transform.

resource "google_bigquery_dataset" "datasets" {
  for_each   = toset(local.bq_datasets)
  project    = var.project_id
  dataset_id = each.value
  location   = var.region == "us-central1" ? "US" : var.region
  labels     = local.labels

  depends_on = [google_project_service.enabled]
}
