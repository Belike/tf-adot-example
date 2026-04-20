###############################################################################
# Core cluster metadata
###############################################################################

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "aws_region" {
  description = "AWS region"
  value       = local.region
}

output "name_prefix" {
  description = "Common name prefix derived from locals"
  value       = var.project_name
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL used for IRSA"
  value       = module.eks.cluster_oidc_issuer_url
}

###############################################################################
# TLS / Ingress / Observability config (used by bootstrap scripts)
###############################################################################

output "cert_email" {
  description = "Email address used for Let's Encrypt / cert-manager"
  value       = local.cert_email
}

output "domain_name" {
  description = "Base DNS domain used for ingress and certificates"
  value       = local.domain_name
}

output "grafana" {
  description = "Whether Grafana stack should be installed"
  value       = local.grafana
}

###############################################################################
# S3
###############################################################################

output "s3_bucket_name" {
  description = "S3 bucket name for Camunda backups"
  value       = module.s3.bucket_name
}

output "s3_bucket_arn" {
  description = "S3 bucket ARN for Camunda backups"
  value       = module.s3.bucket_arn
}

###############################################################################
# IRSA roles
###############################################################################

output "irsa_role_arn_orchestration" {
  description = "IRSA role ARN for Camunda orchestration workloads"
  value       = module.irsa["orchestration"].role_arn
}

output "irsa_role_arn_aws_load_balancer_controller" {
  description = "IRSA role ARN for AWS Load Balancer Controller"
  value       = module.irsa["aws-load-balancer-controller"].role_arn
}

###############################################################################
# Observability IRSA roles
###############################################################################

output "irsa_role_arn_cloudwatch_agent" {
  description = "IRSA role ARN for the CloudWatch agent (Container Insights + FluentBit)"
  value       = module.irsa["cloudwatch-agent"].role_arn
}

output "irsa_role_arn_adot_collector" {
  description = "IRSA role ARN for the ADOT collector (Prometheus scrape -> CloudWatch EMF)"
  value       = module.irsa[local.adot_service_account_name].role_arn
}

###############################################################################
# ADOT collector
###############################################################################

output "adot_collector_namespace" {
  description = "Kubernetes namespace where the ADOT collector runs"
  value       = local.adot_namespace
}

output "adot_collector_service_account" {
  description = "Kubernetes service account name used by the ADOT collector"
  value       = local.adot_service_account_name
}

###############################################################################
# CloudWatch Log Groups
###############################################################################

output "cloudwatch_log_group_application" {
  description = "CloudWatch log group for Container Insights application logs"
  value       = aws_cloudwatch_log_group.container_insights["/aws/containerinsights/${local.cluster_config.cluster_name}/application"].name
}

output "cloudwatch_log_group_performance" {
  description = "CloudWatch log group for Container Insights performance metrics"
  value       = aws_cloudwatch_log_group.container_insights["/aws/containerinsights/${local.cluster_config.cluster_name}/performance"].name
}

output "cloudwatch_log_group_prometheus" {
  description = "CloudWatch log group for ADOT Prometheus -> CloudWatch EMF metrics"
  value       = aws_cloudwatch_log_group.container_insights[local.prometheus_log_group_name].name
}
