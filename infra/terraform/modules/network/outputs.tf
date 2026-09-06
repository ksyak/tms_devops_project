output "ingress_ip" {
  description = "Зарезервированный внешний IP для NGINX Ingress"
  value       = google_compute_address.ingress.address
}

output "network_id" {
  description = "ID VPC"
  value       = google_compute_network.vpc.id
}

output "subnet_id" {
  description = "ID подсети"
  value       = google_compute_subnetwork.subnet.id
}

output "pods_range_name" {
  description = "Имя вторичного диапазона под поды"
  value       = google_compute_subnetwork.subnet.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Имя вторичного диапазона под сервисы"
  value       = google_compute_subnetwork.subnet.secondary_ip_range[1].range_name
}
