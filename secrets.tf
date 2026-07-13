# ServiceTitan credential secret SHELLS. Empty here — the values are written
# later, self-serve, in Studio → Connect ServiceTitan (which uses the
# write-only path granted in iam.tf). Shells must exist first because the
# Platform SA can add versions but cannot create secrets.

resource "google_secret_manager_secret" "st" {
  for_each  = toset(local.st_secret_fields)
  project   = var.project_id
  secret_id = "${var.slug}-servicetitan-${each.value}"
  replication {
    auto {}
  }
  depends_on = [google_project_service.enabled]
}

# depot-sa reads these at sync time.
resource "google_secret_manager_secret_iam_member" "st_depot_reader" {
  for_each  = google_secret_manager_secret.st
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.depot.email}"
}

# ── Relay signing secret (X-Relay-Secret) ────────────────────────────────────
# The relay proxies Platform → Depot status requests. Deployed in bootstrap
# (it needs the internal LB address, created post-Helm); the secret is here.

resource "random_password" "relay" {
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "relay" {
  project   = var.project_id
  secret_id = "depot-relay-secret-${var.slug}"
  replication {
    auto {}
  }
  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "relay" {
  secret      = google_secret_manager_secret.relay.id
  secret_data = random_password.relay.result
}
