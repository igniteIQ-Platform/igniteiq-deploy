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

  deletion_protection = false

  depends_on = [google_project_service.enabled]
}
