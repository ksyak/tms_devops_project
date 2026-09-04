provider "google" {
  project = var.project_id
  region  = var.region
}

# API, без которых остальное не создастся.
#
# disable_on_destroy = false — принципиально: проект переиспользуется под другие
# задачи, и выключение API на terraform destroy сломало бы чужие ресурсы.
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "network" {
  source = "./modules/network"

  name_prefix = var.cluster_name
  region      = var.region

  depends_on = [google_project_service.required]
}

module "gke" {
  source = "./modules/gke"

  project_id   = var.project_id
  cluster_name = var.cluster_name
  zone         = var.zone

  network_id = module.network.network_id
  subnet_id  = module.network.subnet_id

  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name

  node_count        = var.node_count
  machine_type      = var.machine_type
  node_disk_size_gb = var.node_disk_size_gb

  depends_on = [google_project_service.required]
}

module "registry" {
  source = "./modules/registry"

  name_prefix = var.cluster_name
  region      = var.region

  depends_on = [google_project_service.required]
}

module "wif" {
  source = "./modules/wif"

  project_id        = var.project_id
  name_prefix       = var.cluster_name
  github_owner      = var.github_owner
  github_repository = var.github_repository

  depends_on = [google_project_service.required]
}
