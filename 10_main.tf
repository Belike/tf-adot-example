data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# -----------------
# VPC
# -----------------
module "vpc" {
  source = "../modules/vpc"

  name         = local.project_name
  cidr_block   = var.vpc_cidr
  tags         = local.tags
  cluster_name = local.cluster_config.cluster_name
}

# -----------------
# EKS
# -----------------
module "eks" {
  source = "../modules/eks"

  cluster_name    = local.cluster_config.cluster_name
  cluster_version = var.eks_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  tags = local.tags
}

# -----------------
# S3
# -----------------
module "s3" {
  source = "../../../managed-services/s3"

  name_prefix = local.project_name
  environment = local.environment
  tags        = local.tags
}

# -----------------
# Observability locals
# -----------------
locals {
  cloudwatch_log_group_names = toset([
    "/aws/containerinsights/${local.cluster_config.cluster_name}/application",
    "/aws/containerinsights/${local.cluster_config.cluster_name}/host",
    "/aws/containerinsights/${local.cluster_config.cluster_name}/dataplane",
    "/aws/containerinsights/${local.cluster_config.cluster_name}/performance",
    "/aws/containerinsights/${local.cluster_config.cluster_name}/prometheus",
  ])

  adot_namespace              = "observability"
  adot_service_account_name   = "adot-collector"
  prometheus_log_group_name   = "/aws/containerinsights/${local.cluster_config.cluster_name}/prometheus"

  service_accounts = [
    {
      name       = "orchestration"
      namespace  = var.camunda_namespace
      iam        = true
      s3         = true
      cloudwatch = false
      adot       = false
    },
    {
      name       = "optimize"
      namespace  = var.camunda_namespace
      iam        = true
      s3         = true
      cloudwatch = false
      adot       = false
    },
    {
      name       = "keycloak"
      namespace  = var.camunda_namespace
      iam        = false
      cloudwatch = false
      adot       = false
    },
    {
      name       = "web-modeler"
      namespace  = var.camunda_namespace
      iam        = false
      cloudwatch = false
      adot       = false
    },
    {
      name       = "aws-load-balancer-controller"
      namespace  = "kube-system"
      iam        = true
      s3         = false
      cloudwatch = false
      adot       = false
    },
    {
      name       = "cloudwatch-agent"
      namespace  = "amazon-cloudwatch"
      iam        = true
      s3         = false
      cloudwatch = true
      adot       = false
    },
    {
      name       = local.adot_service_account_name
      namespace  = local.adot_namespace
      iam        = true
      s3         = false
      cloudwatch = false
      adot       = true
    }
  ]
}

# -----------------
# IRSA
# -----------------
module "irsa" {
  for_each = { for sa in local.service_accounts : sa.name => sa if sa.iam }

  source = "../modules/iam-irsa"

  name_prefix     = local.project_name
  namespace       = each.value.namespace
  service_account = each.value.name

  oidc_provider_arn = module.eks.cluster_provider_arn

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = concat(

        each.value.s3 ? [
        {
          Effect = "Allow"
          Action = [
            "s3:ListBucket",
            "s3:GetBucketLocation",
            "s3:ListBucketVersions"
          ]
          Resource = module.s3.bucket_arn
        },
        {
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:AbortMultipartUpload",
            "s3:ListBucketMultipartUploads",
            "s3:ListMultipartUploadParts"
          ]
          Resource = "${module.s3.bucket_arn}/*"
        }
      ] : [],

        each.key == "aws-load-balancer-controller" ? [
        {
          Effect = "Allow"
          Action = [
            "elasticloadbalancing:*",
            "ec2:DescribeAccountAttributes",
            "ec2:DescribeAvailabilityZones",
            "ec2:DescribeAddresses",
            "ec2:DescribeInternetGateways",
            "ec2:DescribeVpcs",
            "ec2:DescribeSubnets",
            "ec2:DescribeSecurityGroups",
            "ec2:DescribeInstances",
            "ec2:DescribeNetworkInterfaces",
            "ec2:DescribeTags",
            "ec2:CreateSecurityGroup",
            "ec2:CreateTags",
            "ec2:DeleteTags",
            "ec2:DeleteSecurityGroup",
            "ec2:AuthorizeSecurityGroupIngress",
            "ec2:RevokeSecurityGroupIngress",
            "ec2:AuthorizeSecurityGroupEgress",
            "ec2:RevokeSecurityGroupEgress",
            "shield:GetSubscriptionState",
            "wafv2:GetWebACLForResource",
            "waf-regional:GetWebACLForResource",
            "acm:ListCertificates",
            "acm:DescribeCertificate"
          ]
          Resource = "*"
        }
      ] : [],

      # CloudWatch agent for Container Insights / Fluent Bit
        each.value.cloudwatch ? [
        {
          Effect = "Allow"
          Action = [
            "cloudwatch:PutMetricData",
            "ec2:DescribeVolumes",
            "ec2:DescribeTags",
            "logs:PutLogEvents",
            "logs:DescribeLogStreams",
            "logs:DescribeLogGroups",
            "logs:CreateLogStream",
            "logs:CreateLogGroup",
            "logs:PutRetentionPolicy"
          ]
          Resource = "*"
        }
      ] : [],

      # ADOT collector for Prometheus scrape -> CloudWatch EMF
        each.value.adot ? [
        {
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
            "logs:DescribeLogGroups",
            "logs:DescribeLogStreams",
            "cloudwatch:PutMetricData"
          ]
          Resource = "*"
        }
      ] : []
    )
  })
}

# -----------------
# CloudWatch Log Groups
# -----------------
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = local.cloudwatch_log_group_names

  name              = each.key
  retention_in_days = var.cloudwatch_log_retention_days
  tags              = local.tags
}
