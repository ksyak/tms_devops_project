output "cluster_name" {
  description = "Имя кластера"
  value       = google_container_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint API-сервера"
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "node_service_account" {
  description = "Service account нод"
  value       = google_service_account.nodes.email
}
