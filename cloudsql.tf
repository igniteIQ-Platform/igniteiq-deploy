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

    # 🔴 R4. This database was declared "reconstructable" and is not, any more. Under the
    # Depot v2 engine it holds every connection definition AND every sync cursor, so losing
    # it means a full ServiceTitan re-pull for that tenant -- which ENG-959 turned from a
    # slow afternoon into a question for counsel. Measured 2026-10-22: tapps runs with
    # backups OFF.
    #
    # 09:00 UTC is deliberate: business-hours refreshes fire on the hour 15:00-23:00 UTC,
    # so the window sits clear of every scheduled sync.
    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "09:00"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }
  }

  # 🔴 R4. Was false, with the comment "self-serve teardown; the config DB is reconstructable".
  # Both halves of that have stopped being true: the DB is not reconstructable (above), and no
  # tenant has ever been torn down self-serve. A deliberate teardown now edits this line, which
  # is the point -- it makes destroying a tenant's cursor state a reviewed act, not a plan away.
  deletion_protection = true

  depends_on = [google_service_networking_connection.depot_psa]
}

resource "google_sql_database" "depot" {
  count    = local.v1
  project  = var.project_id
  name     = "db-depot"
  instance = google_sql_database_instance.depot.name
}

# Every live tenant's state holds the un-indexed address; this re-keys it with no API call.
moved {
  from = google_sql_database.depot
  to   = google_sql_database.depot[0]
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
