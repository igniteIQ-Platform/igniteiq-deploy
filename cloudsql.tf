# Depot config database — Cloud SQL Postgres, private IP only. Survives cluster
# loss, so it preserves ingestion cursor state + connector definitions (the DR
# story). Root password is generated here and stored in Secret Manager.

resource "random_password" "depot_sql_root" {
  length  = 24
  special = false
}

resource "google_secret_manager_secret" "depot_sql_root" {
  project   = var.project_id
  secret_id = "depot-sql-root-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "depot_sql_root" {
  secret      = google_secret_manager_secret.depot_sql_root.id
  secret_data = random_password.depot_sql_root.result
}

resource "google_sql_database_instance" "depot" {
  provider         = google-beta
  project          = var.project_id
  name             = "depot-sql"
  region           = var.region
  database_version = "POSTGRES_15"
  root_password    = random_password.depot_sql_root.result

  settings {
    tier              = var.sql_tier
    availability_type = "ZONAL"
    disk_size         = 20
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/${var.project_id}/global/networks/default"
    }
  }

  deletion_protection = false # self-serve teardown; the config DB is reconstructable

  depends_on = [google_service_networking_connection.depot_psa]
}

resource "google_sql_database" "depot" {
  project  = var.project_id
  name     = "db-depot"
  instance = google_sql_database_instance.depot.name
}

# ── Depot v2, ENG-1021. Everything below is additive and OFF unless
# depot_v2_enabled = true; with it false an apply on a live tenant changes nothing. Names carry
# `depot-v2` so they collide with nothing of the running Depot's.

# ── Databases, on the existing instance ──────────────────────────────────────
# db-depot is never touched. The engine and its identity provider each get
# their own. ❓ The engine against Cloud SQL Postgres 15 is unrun.
resource "google_sql_database" "depot_v2" {
  for_each = var.depot_v2_enabled ? toset(["db-depot-v2", "db-depot-v2-idp"]) : toset([])
  project  = var.project_id
  name     = each.value
  instance = google_sql_database_instance.depot.name
}
