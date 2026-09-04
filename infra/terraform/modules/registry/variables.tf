variable "name_prefix" {
  description = "Префикс имён ресурсов, он же repository_id"
  type        = string
}

variable "region" {
  description = "Регион Artifact Registry"
  type        = string
}
