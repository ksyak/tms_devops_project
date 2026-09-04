# Дефолтный Compute SA имеет Editor на весь проект — используем свой.
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

  # node_config дефолтного пула нельзя менять без пересоздания кластера.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Провайдер по умолчанию ставит true, и destroy падает.
  deletion_protection = false

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Dataplane V2: NetworkPolicy без Calico. С legacy-блоком network_policy
  # несовместим, поэтому он не задан.
  datapath_provider = "ADVANCED_DATAPATH"

  # Workload Identity для подов.
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
