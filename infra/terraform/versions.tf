terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Бакет намеренно не зашит: приходит через -backend-config из bootstrap.sh.
  # Так один и тот же код применим в любом проекте.
  backend "gcs" {}
}
