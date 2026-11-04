# The datasets the pipeline reads/writes. Created before any sync or transform.

resource "google_bigquery_dataset" "datasets" {
  for_each   = toset(local.bq_datasets)
  project    = var.project_id
  dataset_id = each.value
  location   = local.bq_location
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
