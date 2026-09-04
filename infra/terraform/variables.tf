variable "project_id" {
  description = "ID проекта GCP"
  type        = string
}

variable "region" {
  description = "Регион для сети и Artifact Registry"
  type        = string
  default     = "europe-central2"
}

variable "zone" {
  description = "Зона кластера. Zonal-кластер дешевле regional и попадает в free tier по management fee"
  type        = string
  default     = "europe-central2-a"
}

variable "cluster_name" {
  description = "Имя кластера, оно же префикс для остальных ресурсов"
  type        = string
  default     = "boutique"
}

variable "node_count" {
  description = "Количество нод"
  type        = number
  # Три ноды покрывают сумму requests, но не оставляют запаса на отказ одной
  # из них, и KubeCPUOvercommit горит постоянно.
  default = 4
}

variable "machine_type" {
  description = "Тип нод"
  type        = string
  default     = "e2-standard-2"
}

variable "node_disk_size_gb" {
  description = "Размер диска ноды"
  type        = number
  default     = 50
}

variable "github_owner" {
  description = "Владелец GitHub-репозитория (логин или организация)"
  type        = string
}

variable "github_repository" {
  description = "Полное имя репозитория в формате owner/repo — под него выписывается доверие WIF"
  type        = string
}
