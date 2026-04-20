variable "project_name" {
  description = "Project name / prefix used for naming resources"
  type        = string
  default     = "example"
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "domain_name" {
  description = "Base domain name (optional)"
  type        = string
  default     = "example.com"
}

variable "cert_email" {
  description = "Email for certificate registration (optional)"
  type        = string
  default     = "admin@example.com"
}

variable "grafana" {
  description = "Enable Grafana deployment"
  type        = bool
  default     = false
}

variable "node_count" {
  description = "Desired node count for default node group"
  type        = number
  default     = 3
}

variable "min_nodes" {
  description = "Minimum nodes for autoscaling"
  type        = number
  default     = 3
}

variable "max_nodes" {
  description = "Maximum nodes for autoscaling"
  type        = number
  default     = 8
}

variable "machine_type" {
  description = "Node instance type (AWS EC2 instance type)"
  type        = string
  default     = "m6i.xlarge"
}

variable "disk_type" {
  description = "Node root volume type (EBS volume type)"
  type        = string
  default     = "gp3"
}

variable "disk_size_gb" {
  description = "Node root volume size in GB"
  type        = number
  default     = 64
}

variable "camunda_namespace" {
  description = "Kubernetes namespace for Camunda deployment"
  type        = string
  default     = "camunda"
}

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "VPC CIDR range"
  type        = string
  default     = "10.0.0.0/16"
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
variable "cloudwatch_log_retention_days" {
  description = "Retention period in days for CloudWatch Container Insights log groups (0 = never expire)"
  type        = number
  default     = 1
}
