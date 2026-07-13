# ── Imperative sequence (the steps Terraform can't model declaratively) ──────
# Two ordered local-execs. Everything above is declarative GCP infra; these two
# handle the Depot runtime lifecycle and the completion callbacks. See the
# design doc §5.1 (ordering traps) and §5.7 (connector distribution).

# 1. Connector-push pre-flight (D1/C2). Once the depot-connectors repo + write
#    grant exist, ask IgniteIQ to copy the pinned connector image into it. The
#    runtime bootstrap depends on this, so the image is in-project before the
#    cluster ever needs it.
resource "null_resource" "connector_push" {
  triggers = {
    repo = google_artifact_registry_repository.depot_connectors.id
    tag  = var.connector_image_tag
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/connector_push.sh"
    interpreter = ["bash", "-c"]
    environment = {
      CALLBACK_BASE_URL  = var.callback_base_url
      PROVISIONING_TOKEN = var.provisioning_token
      ORG_ID             = var.igniteiq_org_id
      PROJECT_ID         = var.project_id
      REGION             = var.region
      TARGET_REPO        = local.connector_repo
      IMAGE_NAME         = var.connector_image_name
      IMAGE_TAG          = var.connector_image_tag
      # The chart is copied in the same request — same target repo, same grant.
      CHART_NAME    = var.depot_chart_name
      CHART_VERSION = var.depot_chart_version
    }
  }

  depends_on = [
    google_artifact_registry_repository.depot_connectors,
    google_artifact_registry_repository_iam_member.publisher_writer,
  ]
}

# 2. Depot runtime bootstrap — cluster app config + relay + infra-ready.
#    Runs the whole runtime sequence in one ordered script (set -euo pipefail).
resource "null_resource" "depot_bootstrap" {
  triggers = {
    cluster       = google_container_cluster.depot.id
    chart_version = var.depot_chart_version
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/depot_bootstrap.sh"
    interpreter = ["bash", "-c"]
    environment = {
      PROJECT_ID         = var.project_id
      REGION             = var.region
      SLUG               = var.slug
      NAMESPACE          = local.depot_namespace
      K8S_SA             = local.depot_k8s_sa
      DEPOT_SA           = google_service_account.depot.email
      SQL_PRIVATE_IP     = google_sql_database_instance.depot.private_ip_address
      SQL_DB             = google_sql_database.depot.name
      SQL_ROOT_SECRET    = google_secret_manager_secret.depot_sql_root.secret_id
      CHART_OCI_REF      = local.chart_oci_ref
      CHART_VERSION      = var.depot_chart_version
      CONNECTOR_IMAGE    = local.connector_image
      RAW_DATASET        = "depot_raw"
      INTERNAL_DATASET   = "depot_internal"
      RELAY_SECRET_NAME  = google_secret_manager_secret.relay.secret_id
      CALLBACK_BASE_URL  = var.callback_base_url
      PROVISIONING_TOKEN = var.provisioning_token
      ORG_ID             = var.igniteiq_org_id
    }
  }

  depends_on = [
    null_resource.connector_push,
    google_container_cluster.depot,
    google_service_account_iam_member.depot_wi,
    google_sql_database.depot,
    google_artifact_registry_repository_iam_member.node_reader,
    google_secret_manager_secret_version.relay,
    google_bigquery_dataset.datasets,
  ]
}
