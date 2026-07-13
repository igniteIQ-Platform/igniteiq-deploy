locals {
  # Kubernetes namespace + workload SA for the Depot ingestion runtime.
  # NOTE: the workload SA name is fixed by the upstream ingestion runtime's
  # internal launcher config (JOB_KUBE_SERVICEACCOUNT) and cannot be overridden
  # by chart values. It is a cluster-INTERNAL, kubectl-only identity — never
  # shown in Studio or the GCP console (ENG-260, boundary "P"). The pre-created
  # SA + Workload Identity binding must match it exactly or connector pods fail.
  depot_namespace = "depot"
  depot_k8s_sa    = var.workload_k8s_sa

  # In-project OCI artifacts (both published by IgniteIQ via the connector-push
  # callback into the depot-connectors repository — the image and the Helm chart
  # ride the same repo and the same publisher-writer / node-reader grants).
  connector_repo  = "depot-connectors"
  connector_image = "${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}/${var.connector_image_name}:${var.connector_image_tag}"
  chart_oci_ref   = "oci://${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}/${var.depot_chart_name}"

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
