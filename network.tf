# Private Services Access — the peering range Cloud SQL uses for its private IP.
# ORDERING TRAP #1: this range + peering MUST exist before the SQL instance, or
# the instance fails to get a private IP. depends_on is set on the instance.

resource "google_compute_global_address" "depot_psa" {
  provider      = google-beta
  name          = "depot-psa"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = "projects/${var.project_id}/global/networks/default"

  depends_on = [google_project_service.enabled]
}

resource "google_service_networking_connection" "depot_psa" {
  network                 = "projects/${var.project_id}/global/networks/default"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.depot_psa.name]
}
