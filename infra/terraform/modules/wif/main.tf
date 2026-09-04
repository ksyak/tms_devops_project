# GitHub Actions обменивает OIDC-токен на короткоживущий токен GCP.
# Ключей сервисного аккаунта не создаётся.

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${var.name_prefix}-gh-pool"
  display_name              = "GitHub Actions"
  description               = "Пул доверия для CI Online Boutique"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "${var.name_prefix}-gh-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  # Без условия подошёл бы токен любого репозитория GitHub.
  attribute_condition = "assertion.repository_owner == \"${var.github_owner}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ci" {
  account_id   = "${var.name_prefix}-ci"
  display_name = "GitHub Actions CI"
}

resource "google_project_iam_member" "ci" {
  for_each = toset([
    "roles/artifactregistry.writer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# Доверие сужено до одного репозитория.
resource "google_service_account_iam_member" "ci_wif" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
