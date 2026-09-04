variable "project_id" {
  description = "ID проекта GCP"
  type        = string
}

variable "cluster_name" {
  description = "Имя кластера"
  type        = string
}

variable "zone" {
  description = "Зона кластера"
  type        = string
}

variable "network_id" {
  description = "ID VPC"
  type        = string
}

variable "subnet_id" {
  description = "ID подсети"
  type        = string
}

variable "pods_range_name" {
  description = "Имя вторичного диапазона под поды"
  type        = string
}

variable "services_range_name" {
  description = "Имя вторичного диапазона под сервисы"
  type        = string
}

variable "node_count" {
  description = "Количество нод в пуле"
  type        = number
}

variable "machine_type" {
  description = "Тип нод"
  type        = string
}

variable "node_disk_size_gb" {
  description = "Размер диска ноды"
  type        = number
}
