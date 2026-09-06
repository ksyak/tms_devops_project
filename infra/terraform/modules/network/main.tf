# Внешний адрес для NGINX Ingress резервируем заранее, а не отдаём на откуп
# балансировщику. Иначе имя хоста (<адрес>.nip.io) неизвестно до установки
# Ingress, и манифесты с этим именем нечем отрендерить.
resource "google_compute_address" "ingress" {
  name         = "${var.name_prefix}-ingress-ip"
  region       = var.region
  address_type = "EXTERNAL"
  description  = "Внешний IP NGINX Ingress Controller"
}

resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# VPC-native кластеру нужны вторичные диапазоны под поды и сервисы.
# Задаём их явно, а не через auto-allocate, чтобы адресация была предсказуемой.
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name_prefix}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${var.name_prefix}-pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "${var.name_prefix}-services"
    ip_cidr_range = var.services_cidr
  }
}
