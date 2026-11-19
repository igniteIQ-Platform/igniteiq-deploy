# ── QuickBooks Desktop — off unless quickbooks_desktop_enabled = true ─────────────────────
#
# QuickBooks Desktop has no cloud API. Intuit's Web Connector, on the customer's own Windows
# server, calls OUT to a SOAP service on a schedule and runs the read-only queries it returns.
# Nothing calls in to that server. Two services, each with one job:
#
#   depot-qbwc       answers the Web Connector and lands every record in the landing bucket.
#                    Public: the Web Connector cannot present a Google identity, so a
#                    generated password, checked in constant time, is the gate.
#   depot-read-api   serves the landed records to the Depot v2 ingestion runtime, which loads
#                    them into BigQuery. Public with a generated bearer token, as the relay is.
#                    Serves only the streams named in quickbooks_desktop_promoted.
#
# Everything here is additive. With the flag off, an apply on a live tenant changes nothing.
# Both images come from this project's depot-connectors repository, pinned by digest.
#
# Nothing in this file touches QuickBooks or the customer's server. Registering the service
# with the Web Connector (the .QWC file) and approving it in QuickBooks are done on that server,
# by the customer.

locals {
  qbd             = var.quickbooks_desktop_enabled ? 1 : 0
  qbd_bucket      = "${var.project_id}-depot-landing"
  qbd_qbwc_image  = "${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}/qbwc@${var.quickbooks_desktop_qbwc_image_digest}"
  qbd_read_image  = "${var.region}-docker.pkg.dev/${var.project_id}/${local.connector_repo}/read-api@${var.quickbooks_desktop_read_api_image_digest}"
  qbd_digest_rule = "^sha256:[0-9a-f]{64}$"

  # The Web Connector service's settings. The password is not here: it is mounted from
  # Secret Manager. Every key the service accepts is validated by the service at start-up,
  # so a wrong key fails the revision rather than running with a default nobody chose.
  qbd_qbwc_config = merge(
    {
      tenant      = var.slug
      timezone    = var.quickbooks_desktop_timezone
      username    = var.quickbooks_desktop_username
      run_windows = var.quickbooks_desktop_run_windows
    },
    var.quickbooks_desktop_history_start == "" ? {} : { history_start = var.quickbooks_desktop_history_start },
    var.quickbooks_desktop_qbwc_settings,
  )
}

# Cloud Storage is on in almost every project already; enabling it is a no-op there and keeps
# a project where it is off from failing the bucket below. Kept on destroy, as apis.tf keeps its own.
resource "google_project_service" "qbd_storage" {
  count                      = local.qbd
  project                    = var.project_id
  service                    = "storage.googleapis.com"
  disable_on_destroy         = false
  disable_dependent_services = false
}

# ── Landing bucket ──────────────────────────────────────────────────────────────────────
# Every record either writer lands, kept permanently: promotion can later serve a stream
# from its first record, so nothing here expires. depot-qbwc writes under quickbooks/.
resource "google_storage_bucket" "depot_landing" {
  count                       = local.qbd
  project                     = var.project_id
  name                        = local.qbd_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  depends_on = [google_project_service.enabled, google_project_service.qbd_storage]
}

# ── Service accounts, one per service ───────────────────────────────────────────────────
resource "google_service_account" "depot_qbwc" {
  count        = local.qbd
  project      = var.project_id
  account_id   = "depot-qbwc"
  display_name = "Depot QuickBooks Web Connector service — writes the landing bucket"
}

resource "google_service_account" "depot_read_api" {
  count        = local.qbd
  project      = var.project_id
  account_id   = "depot-read-api"
  display_name = "Depot read API — reads the landing bucket"
}

# Object admin, not creator: the service rewrites its run manifests and state file with
# generation preconditions, which needs overwrite and read.
resource "google_storage_bucket_iam_member" "depot_qbwc_writer" {
  count  = local.qbd
  bucket = google_storage_bucket.depot_landing[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.depot_qbwc[0].email}"
}

resource "google_storage_bucket_iam_member" "depot_read_api_reader" {
  count  = local.qbd
  bucket = google_storage_bucket.depot_landing[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.depot_read_api[0].email}"
}

# ── Secrets, generated once ─────────────────────────────────────────────────────────────
# The Web Connector password is typed into the Web Connector on the customer's server when
# the .QWC is imported; whoever does that reads it from this secret. The read API token goes
# into the ingestion runtime's connection for this source. Neither is ever emailed.
resource "random_password" "qbd" {
  for_each = var.quickbooks_desktop_enabled ? toset(["qbwc-password", "read-api-token"]) : toset([])
  length   = 48
  special  = false
}

resource "google_secret_manager_secret" "qbd" {
  for_each  = var.quickbooks_desktop_enabled ? toset(["qbwc-password", "read-api-token"]) : toset([])
  project   = var.project_id
  secret_id = "depot-${each.value}-${var.slug}"
  replication {
    auto {}
  }
  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "qbd" {
  # Static keys, for the reason secrets.tf gives on depot_v2: import evaluates the whole
  # configuration up front and cannot defer an unknown key set.
  for_each    = var.quickbooks_desktop_enabled ? toset(["qbwc-password", "read-api-token"]) : toset([])
  secret      = google_secret_manager_secret.qbd[each.key].id
  secret_data = random_password.qbd[each.key].result
}

resource "google_secret_manager_secret_iam_member" "depot_qbwc_password_reader" {
  count     = local.qbd
  project   = var.project_id
  secret_id = google_secret_manager_secret.qbd["qbwc-password"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.depot_qbwc[0].email}"
}

resource "google_secret_manager_secret_iam_member" "depot_read_api_token_reader" {
  count     = local.qbd
  project   = var.project_id
  secret_id = google_secret_manager_secret.qbd["read-api-token"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.depot_read_api[0].email}"
}

# ── depot-qbwc ──────────────────────────────────────────────────────────────────────────
resource "google_cloud_run_v2_service" "depot_qbwc" {
  count               = local.qbd
  project             = var.project_id
  name                = "depot-qbwc"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  labels              = local.labels

  template {
    service_account = google_service_account.depot_qbwc[0].email
    # 🔴 ONE instance. A Web Connector session lives in one process's memory between SOAP
    # calls; a second instance would answer half a conversation it never started. The
    # service's lease in its state file refuses a second session anyway, so more instances
    # fail runs rather than corrupt data, but they still fail runs.
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    max_instance_request_concurrency = 8
    timeout                          = "300s"

    containers {
      image = local.qbd_qbwc_image
      env {
        name  = "QBWC_BUCKET"
        value = google_storage_bucket.depot_landing[0].name
      }
      env {
        name  = "QBWC_CONFIG"
        value = jsonencode(local.qbd_qbwc_config)
      }
      env {
        name = "QBWC_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.qbd["qbwc-password"].secret_id
            version = "latest"
          }
        }
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }
      startup_probe {
        http_get {
          path = "/health"
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = can(regex(local.qbd_digest_rule, var.quickbooks_desktop_qbwc_image_digest))
      error_message = "quickbooks_desktop_qbwc_image_digest must be the sha256 digest of the qbwc image in this project's depot-connectors repository (sha256:<64 hex>)."
    }
    precondition {
      condition     = var.quickbooks_desktop_username != ""
      error_message = "quickbooks_desktop_username is required: it is the user name the .QWC file sends."
    }
  }

  depends_on = [
    google_project_service.enabled,
    google_secret_manager_secret_version.qbd,
    google_secret_manager_secret_iam_member.depot_qbwc_password_reader,
    google_storage_bucket_iam_member.depot_qbwc_writer,
  ]
}

# The Web Connector cannot authenticate to Google. The service's own password check is the gate.
resource "google_cloud_run_v2_service_iam_member" "depot_qbwc_public" {
  count    = local.qbd
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.depot_qbwc[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ── depot-read-api ──────────────────────────────────────────────────────────────────────
resource "google_cloud_run_v2_service" "depot_read_api" {
  count               = local.qbd
  project             = var.project_id
  name                = "depot-read-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  labels              = local.labels

  template {
    service_account = google_service_account.depot_read_api[0].email
    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }
    timeout = "300s"

    containers {
      image = local.qbd_read_image
      env {
        name  = "READ_API_BUCKET"
        value = google_storage_bucket.depot_landing[0].name
      }
      env {
        # Unset or empty serves nothing. A stream is served only once it is listed here.
        name  = "READ_API_PROMOTED"
        value = join(",", var.quickbooks_desktop_promoted)
      }
      env {
        name = "READ_API_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.qbd["read-api-token"].secret_id
            version = "latest"
          }
        }
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }
      startup_probe {
        http_get {
          path = "/health"
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = can(regex(local.qbd_digest_rule, var.quickbooks_desktop_read_api_image_digest))
      error_message = "quickbooks_desktop_read_api_image_digest must be the sha256 digest of the read-api image in this project's depot-connectors repository (sha256:<64 hex>)."
    }
  }

  depends_on = [
    google_project_service.enabled,
    google_secret_manager_secret_version.qbd,
    google_secret_manager_secret_iam_member.depot_read_api_token_reader,
    google_storage_bucket_iam_member.depot_read_api_reader,
  ]
}

# Public, with the bearer token as the gate, as the relay is: the ingestion runtime calls it
# from the cluster and holds the token in its connection secret.
resource "google_cloud_run_v2_service_iam_member" "depot_read_api_public" {
  count    = local.qbd
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.depot_read_api[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
