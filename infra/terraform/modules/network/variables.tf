variable "name_prefix" {
  description = "Префикс имён ресурсов"
  type        = string
}

variable "region" {
  description = "Регион подсети"
  type        = string
}

variable "subnet_cidr" {
  description = "Диапазон нод"
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Вторичный диапазон под поды"
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Вторичный диапазон под сервисы"
  type        = string
  default     = "10.30.0.0/20"
}
