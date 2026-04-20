locals {
  project_name = var.project_name
  region       = var.region
  domain_name  = var.domain_name
  cert_email   = var.cert_email
  environment  = var.environment
  grafana      = var.grafana

  tags = {
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terraform"
  }

  cluster_config = {
    cluster_name = "${local.project_name}-${local.environment}-eks"
    location     = local.region

    node_count = var.node_count
    min_nodes  = var.min_nodes
    max_nodes  = var.max_nodes

    machine_type = var.machine_type
    disk_type    = var.disk_type
    disk_size_gb = var.disk_size_gb

    tags = local.tags
  }
}
