output "repository_url" {
  description = "Базовый URL для тегов образов"
  value       = "${var.region}-docker.pkg.dev/${google_artifact_registry_repository.docker.project}/${google_artifact_registry_repository.docker.repository_id}"
}

output "repository_id" {
  description = "ID репозитория"
  value       = google_artifact_registry_repository.docker.repository_id
}
