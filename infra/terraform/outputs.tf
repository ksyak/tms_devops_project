output "cluster_name" {
  description = "Имя кластера GKE"
  value       = module.gke.cluster_name
}

output "cluster_zone" {
  description = "Зона кластера"
  value       = var.zone
}

output "kubeconfig_command" {
  description = "Команда для получения kubeconfig — kubeconfig в git не хранится"
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --zone ${var.zone} --project ${var.project_id}"
}

output "registry_url" {
  description = "Базовый URL Artifact Registry для тегов образов"
  value       = module.registry.repository_url
}

output "wif_provider" {
  description = "Полное имя WIF-провайдера — в секрет GitHub Actions"
  value       = module.wif.provider_name
}

output "ci_service_account" {
  description = "Service account, которым CI пушит образы — в секрет GitHub Actions"
  value       = module.wif.service_account_email
}
