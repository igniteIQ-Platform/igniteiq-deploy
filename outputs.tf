output "project_id" {
  value       = var.project_id
  description = "The project this Depot stack was provisioned into."
}

output "cluster_name" {
  value       = google_container_cluster.depot.name
  description = "Depot ingestion cluster."
}

output "sql_private_ip" {
  value       = google_sql_database_instance.depot.private_ip_address
  description = "Depot config database private IP."
}

output "connector_repository" {
  value       = google_artifact_registry_repository.depot_connectors.name
  description = "In-project Depot connector repository."
}

output "servicetitan_secret_shells" {
  value       = [for s in google_secret_manager_secret.st : s.secret_id]
  description = "Empty ServiceTitan credential secrets — populated later, self-serve, in Studio."
}

# The relay URL / workspace ID / client creds are produced by the runtime
# bootstrap and reported to IgniteIQ via the infra-ready callback; they are not
# Terraform-managed outputs (they originate inside the cluster at apply time).
