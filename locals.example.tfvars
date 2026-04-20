#############################################
# Example Terraform variables
#
# Copy this file to:
#   locals.auto.tfvars
# and adjust the values for your environment.
#
#############################################

# --- Project / Environment -----------------

project_name = "example-project"
environment  = "dev"
region       = "eu-central-1"

# --- Domain / Certificates -----------------

domain_name = "example.com"
cert_email  = "admin@example.com"

# --- EKS Cluster Sizing --------------------

node_count = 3
min_nodes  = 3
max_nodes  = 8

machine_type = "m6i.xlarge"

disk_type    = "gp3"
disk_size_gb = 64

# --- Optional ------------------------------

grafana = false

# --- Observability -------------------------
# Retention period for Container Insights CloudWatch log groups (days).
# Set to 0 for no expiry.
cloudwatch_log_retention_days = 1
