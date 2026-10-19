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

  # ── Depot v2, ENG-1021 — see the gated resources in iam.tf, secrets.tf, cloudsql.tf,
  # bigquery.tf and bootstrap.tf ──
  v1                 = var.depot_v1_enabled ? 1 : 0
  v2                 = var.depot_v2_enabled ? 1 : 0
  v2_only            = !var.depot_v1_enabled && var.depot_v2_enabled ? 1 : 0 # v2 then deploys the relay itself
  v2_namespace       = "depot-v2"
  v2_ksa             = "depot-v2-server" # the chart's ONE Kubernetes ServiceAccount, for every component
  operator           = var.depot_v2_enabled && var.depot_operator_chart_version != "" ? 1 : 0
  operator_namespace = "depot-operator"
  operator_ksa       = "depot-operator" # charts/depot-operator serviceAccount.name
  # What connector-push is asked to copy for v2. Empty while the flag is off, so the request a
  # tenant without v2 makes is byte-for-byte the one it made before v2 existed.
  v2_chart_name          = var.depot_v2_enabled ? var.depot_v2_chart_name : ""
  v2_chart_version       = var.depot_v2_enabled ? var.depot_v2_chart_version : ""
  operator_chart_name    = var.depot_v2_enabled && var.depot_operator_chart_version != "" ? var.depot_operator_chart_name : ""
  operator_chart_version = var.depot_v2_enabled ? var.depot_operator_chart_version : ""
  operator_image_digest  = var.depot_v2_enabled ? var.depot_operator_image_digest : ""
  v2_secret_prefix       = "depot-v2-${var.slug}" # SECRETS_PREFIX; the engine names its secrets <prefix>-<sha256>

  # The engine creates REGIONAL secrets, whose resource name carries a location segment; a
  # condition on the global form alone matches nothing it creates. resource.name carries the
  # project NUMBER, not the id.
  v2_secret_condition = join(" || ", [
    "resource.name.startsWith(\"projects/${data.google_project.this.number}/secrets/${local.v2_secret_prefix}-\")",
    "resource.name.startsWith(\"projects/${data.google_project.this.number}/locations/${var.region}/secrets/${local.v2_secret_prefix}-\")",
  ])

  # Install-time credentials, generated ONCE here and never by a script: the
  # engine creates its admin and sets the IdP password on first boot only, so a
  # regenerated value locks the deployment out.
  # No relay secret here: the tenant's one relay keeps the RELAY_SECRET it already has.
  v2_secrets = ["client-secret", "admin-password", "idp-admin-password", "auth-client-secret"]
}
