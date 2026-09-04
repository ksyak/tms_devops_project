# Отдельный service account для нод вместо дефолтного Compute SA:
# у дефолтного роль Editor на весь проект, а проект у нас общий.
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes: ${var.cluster_name}"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone

  network    = var.network_id
  subnetwork = var.subnet_id

  # Пул создаём отдельным ресурсом: у дефолтного нельзя менять node_config
  # без пересоздания кластера.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Без этого terraform destroy падает, и teardown ломается на ровном месте.
  deletion_protection = false

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Dataplane V2 даёт NetworkPolicy из коробки (бонус ТЗ) и заодно
  # исключает конфликт с legacy-блоком network_policy.
  datapath_provider = "ADVANCED_DATAPATH"

  # Workload Identity: поды ходят в API GCP без ключей в секретах.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }

    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"
}

resource "google_container_node_pool" "primary" {
  name     = "primary"
  location = var.zone
  cluster  = google_container_cluster.this.name

  node_count = var.node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = "pd-balanced"

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = {
      role = "app"
    }
  }

  lifecycle {
    ignore_changes = [node_config[0].labels]
  }
}
