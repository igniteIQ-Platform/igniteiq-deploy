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
    # Depot v2 (ENG-1085): a new chart version or operator digest must be copied in before
    # depot_v2_bootstrap re-runs and asks the cluster for it. Empty strings while v2 is off.
    v2_chart         = local.v2_chart_version
    operator_version = local.operator_chart_version
    operator_digest  = local.operator_image_digest
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
      # Depot v2: the engine chart, the operator chart and the operator image, into the same
      # repo. All empty while depot_v2_enabled is false, and the script then sends none of them,
      # so a tenant without v2 makes the exact request it made before.
      V2_CHART_NAME          = local.v2_chart_name
      V2_CHART_VERSION       = local.v2_chart_version
      OPERATOR_CHART_NAME    = local.operator_chart_name
      OPERATOR_CHART_VERSION = local.operator_chart_version
      OPERATOR_IMAGE_DIGEST  = local.operator_image_digest
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
  count = local.v1
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
      SQL_DB             = google_sql_database.depot[0].name
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

# Re-keys every live tenant's state with no API call: without it the bootstrap would re-run.
moved {
  from = null_resource.depot_bootstrap
  to   = null_resource.depot_bootstrap[0]
}

# ── Depot v2, ENG-1021. Everything below is additive and OFF unless
# depot_v2_enabled = true; with it false an apply on a live tenant changes nothing. Names carry
# `depot-v2` so they collide with nothing of the running Depot's.

# ── Bootstrap ────────────────────────────────────────────────────────────────
# Shorter than depot_bootstrap.sh: auth is on from the first install, no connector
# is registered and nothing is read back out of the cluster. It creates the BigQuery
# sink, as depot_bootstrap.sh creates its destination, then reaches the relay: it
# updates the one depot_bootstrap.sh deployed, or with v1 off deploys it. Last it
# registers the engine with infra-ready. That is not the switch: a tenant already on
# the running Depot stays on it, and only a never-registered tenant (v2 only) starts
# on v2 (igniteiq-platform onboarding/infraReady.ts).
# Re-runs on a chart version change, which is how an upgrade reaches the tenant.
resource "null_resource" "depot_v2_bootstrap" {
  count = local.v2
  triggers = {
    cluster          = google_container_cluster.depot.id
    chart_version    = var.depot_v2_chart_version
    operator_version = var.depot_operator_chart_version
    operator_digest  = var.depot_operator_image_digest
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/depot_v2_bootstrap.sh"
    interpreter = ["bash", "-c"]
    environment = {
      PROJECT_ID      = var.project_id
      REGION          = var.region
      SLUG            = var.slug
      CLUSTER_NAME    = google_container_cluster.depot.name
      NAMESPACE       = local.v2_namespace
      DEPOT_SA        = google_service_account.depot.email
      IMAGE_REPO      = "${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}"
      SQL_PRIVATE_IP  = google_sql_database_instance.depot.private_ip_address
      SQL_ROOT_SECRET = google_secret_manager_secret.depot_sql_root.secret_id
      SECRET_PREFIX   = local.v2_secret_prefix
      BQ_LOCATION     = google_bigquery_dataset.depot_raw_v2[0].location # the sink's location must equal the dataset's
      CHART_OCI_REF   = "oci://${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}/${var.depot_v2_chart_name}"
      CHART_VERSION   = var.depot_v2_chart_version
      # The operator (decision 0045, option C). Empty OPERATOR_CHART_VERSION installs none.
      OPERATOR_NAMESPACE     = local.operator_namespace
      OPERATOR_CHART_OCI_REF = "oci://${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}/${var.depot_operator_chart_name}"
      OPERATOR_CHART_VERSION = var.depot_operator_chart_version
      OPERATOR_IMAGE_DIGEST  = var.depot_operator_image_digest
      PLATFORM_URL           = var.callback_base_url # also the audience of the operator's identity token
      # The relay: deployed here when v1 is off (DEPLOY_RELAY=1), updated otherwise.
      DEPLOY_RELAY      = tostring(local.v2_only)
      RELAY_IMAGE       = "${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}/depot-relay:latest"
      RELAY_SECRET_NAME = google_secret_manager_secret.relay.secret_id
      # Registration (infra-ready, engine V2).
      CALLBACK_BASE_URL  = var.callback_base_url
      PROVISIONING_TOKEN = var.provisioning_token
      ORG_ID             = var.igniteiq_org_id
    }
  }

  depends_on = [
    null_resource.connector_push,  # the v2 chart, operator chart and operator image are copied there
    null_resource.depot_bootstrap, # with v1 on, deploys the one relay this script then points at v2
    google_secret_manager_secret_version.relay,
    google_secret_manager_secret_iam_member.depot_v2_relay_secret_reader,
    google_container_cluster.depot,
    google_service_account_iam_member.depot_v2_wi,
    google_project_iam_member.depot_v2_secret_creator,
    google_project_iam_member.depot_v2_secret_owner,
    google_secret_manager_secret_version.depot_v2,
    google_secret_manager_secret_iam_member.depot_v2_relay_reader,
    google_sql_database.depot_v2,
    google_bigquery_dataset.depot_raw_v2,
    google_service_account_iam_member.depot_operator_wi,
    google_artifact_registry_repository_iam_member.depot_operator_chart_reader,
  ]
}
