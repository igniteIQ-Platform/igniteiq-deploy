# Depot connectors repository — lives in the customer's OWN project. IgniteIQ
# pushes the pinned connector image into it (via the connector-push callback),
# and the ingestion cluster pulls only from here — no public or cross-project
# pull. The customer grants IgniteIQ write on THEIR repo (not the reverse), so
# no grant-list accumulates on the IgniteIQ side.

resource "google_artifact_registry_repository" "depot_connectors" {
  project       = var.project_id
  location      = var.region
  repository_id = local.connector_repo
  format        = "DOCKER"
  description   = "Depot connector images (IgniteIQ-published, tenant-local)."

  depends_on = [google_project_service.enabled]
}

# IgniteIQ's publisher SA may WRITE the image into this repo. Write-only: it
# cannot deploy, read data, or do anything else in the project.
resource "google_artifact_registry_repository_iam_member" "publisher_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.depot_connectors.location
  repository = google_artifact_registry_repository.depot_connectors.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.igniteiq_publisher_sa}"
}

# The Autopilot node identity (default compute SA) reads the image at pull time.
resource "google_artifact_registry_repository_iam_member" "node_reader" {
  project    = var.project_id
  location   = google_artifact_registry_repository.depot_connectors.location
  repository = google_artifact_registry_repository.depot_connectors.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}
