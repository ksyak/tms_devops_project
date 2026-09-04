variable "project_id" {
  description = "ID проекта GCP"
  type        = string
}

variable "name_prefix" {
  description = "Префикс имён ресурсов"
  type        = string
}

variable "github_owner" {
  description = "Владелец репозитория — сужает доверие провайдера"
  type        = string
}

variable "github_repository" {
  description = "Репозиторий в формате owner/repo — сужает право на impersonation"
  type        = string
}
