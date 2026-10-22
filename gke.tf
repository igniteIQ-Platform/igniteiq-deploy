# Depot ingestion cluster — GKE Autopilot. Autopilot auto-sizes pod resources,
# so the ingestion control plane and dynamically-launched connector pods
# schedule with no hand-set requests.

resource "google_container_cluster" "depot" {
  provider         = google-beta
  project          = var.project_id
  name             = "depot-cluster"
  location         = var.region
  enable_autopilot = true

  # Workload Identity is on by default under Autopilot; declared for clarity.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # 🔴 R4. The cluster can be rebuilt, but not while a tenant is syncing, and a destroy here
  # takes both engines with it. Protected for the same reason as the database.
  deletion_protection = true

  lifecycle {
    precondition {
      condition     = var.depot_v1_enabled || var.depot_v2_enabled
      error_message = "At least one of depot_v1_enabled and depot_v2_enabled must be true: a cluster with no ingestion runtime has nothing to run."
    }
  }

  depends_on = [google_project_service.enabled]
}
