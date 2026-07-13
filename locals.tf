locals {
  # Kubernetes namespace + workload SA for the Depot ingestion runtime.
  depot_namespace = "depot"
  depot_k8s_sa    = "depot-ingest" # set via the Depot chart values (not a vendor default)

  # In-project connector image (pushed by IgniteIQ via the connector-push
  # callback into the depot-connectors repository).
  connector_repo  = "depot-connectors"
  connector_image = "${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}/${var.connector_image_name}:${var.connector_image_tag}"

  # Workload Identity member for the ingestion runtime's k8s SA.
  wi_member = "serviceAccount:${var.project_id}.svc.id.goog[${local.depot_namespace}/${local.depot_k8s_sa}]"

  # ServiceTitan credential secret shells (values written later, self-serve, in
  # Studio → Connect ServiceTitan; this module only creates the empty shells).
  st_secret_fields = ["client-id", "client-secret", "app-key", "tenant-id"]

  # BigQuery datasets the pipeline reads/writes.
  bq_datasets = [
    "depot_raw",      # landed source data
    "depot_internal", # destination working set
    "forge_staging",  # dbt staging
    "forge_intermediate",
    "ontology", # published marts/facts (Vault reads these)
  ]

  labels = {
    managed-by = "igniteiq-deploy"
    tenant     = var.slug
  }
}
