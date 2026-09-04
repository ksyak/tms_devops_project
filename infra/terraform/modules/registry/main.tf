resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = var.name_prefix
  format        = "DOCKER"
  description   = "Образы микросервисов Online Boutique"
}
