output "provider_name" {
  description = "Полное имя провайдера для google-github-actions/auth"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "service_account_email" {
  description = "Service account, которым CI пушит образы"
  value       = google_service_account.ci.email
}
