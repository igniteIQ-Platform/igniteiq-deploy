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
