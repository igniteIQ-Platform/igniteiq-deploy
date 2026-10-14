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

# ── Depot v2, ENG-1021. Everything below is additive and OFF unless
# depot_v2_enabled = true; with it false an apply on a live tenant changes nothing. Names carry
# `depot-v2` so they collide with nothing of the running Depot's.

# ── Install-time secrets ─────────────────────────────────────────────────────
resource "random_password" "depot_v2" {
  for_each = var.depot_v2_enabled ? toset(local.v2_secrets) : toset([])
  length   = 48
  special  = false
}

resource "google_secret_manager_secret" "depot_v2" {
  for_each  = var.depot_v2_enabled ? toset(local.v2_secrets) : toset([])
  project   = var.project_id
  secret_id = "depot-v2-${each.value}-${var.slug}"
  replication {
    auto {}
  }
  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "depot_v2" {
  for_each    = google_secret_manager_secret.depot_v2
  secret      = each.value.id
  secret_data = random_password.depot_v2[each.key].result
}

# The tenant's one relay runs as depot-sa and, for v2, mounts `depot-v2-client-secret-<slug>`
# as a file from Secret Manager (--update-secrets in the v2 bootstrap), which it exchanges
# for the engine's token (ENG-1084). Its RELAY_SECRET is the one it already has. The prefix
# condition above does not match this secret (the prefix ends in `<slug>-`), so it needs its
# own grant, on the one secret, as secrets.tf grants depot-sa on the ServiceTitan shells.
resource "google_secret_manager_secret_iam_member" "depot_v2_relay_reader" {
  for_each  = local.v2 == 1 ? toset(["client-secret"]) : toset([])
  project   = var.project_id
  secret_id = google_secret_manager_secret.depot_v2[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.depot.email}"
}
