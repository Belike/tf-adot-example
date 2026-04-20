# adot-tf-example

AWS-native observability stack for EKS using Terraform. Provisions an EKS cluster with AWS-managed addons:

| Addon | Purpose |
|---|---|
| `amazon-cloudwatch-observability` | CloudWatch Container Insights (metrics) + FluentBit (log collection) |
| `adot` | AWS Distro for OpenTelemetry — OTEL metrics/traces pipeline to CloudWatch EMF and X-Ray |

Both addons are feature-flagged and enabled by default.

---

## Provisioned Assets

| Asset | Description |
|---|---|
| VPC | 3-AZ layout, 3 public + 3 private subnets, single NAT gateway |
| EKS cluster | Managed node group (on-demand), EBS CSI driver addon |
| IRSA roles | Camunda workloads, AWS LB Controller, CloudWatch agent, ADOT collector |
| S3 bucket | Camunda backup storage |
| CloudWatch log groups | 4 Container Insights log groups pre-created with configurable retention |
| EKS addon: `amazon-cloudwatch-observability` | CloudWatch Container Insights + FluentBit (optional) |
| EKS addon: `adot` | OpenTelemetry Operator for custom OTEL pipelines (optional) |

---

## Observability Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  EKS Cluster                                                         │
│                                                                      │
│  ┌─────────────────────────────────────┐                            │
│  │  amazon-cloudwatch-observability    │                            │
│  │  ┌──────────────────┐              │                            │
│  │  │  CloudWatch Agent │─────────────┼──► CloudWatch Metrics      │
│  │  │  (Container       │             │    (Container Insights)     │
│  │  │   Insights)       │             │                            │
│  │  └──────────────────┘              │                            │
│  │  ┌──────────────────┐              │                            │
│  │  │  FluentBit        │─────────────┼──► CloudWatch Logs         │
│  │  │  (DaemonSet)      │             │    /aws/containerinsights/  │
│  │  └──────────────────┘              │    {cluster}/{stream}       │
│  └─────────────────────────────────────┘                            │
│                                                                      │
│  ┌─────────────────────────────────────┐                            │
│  │  adot (OpenTelemetry Operator)      │                            │
│  │  ┌──────────────────────────────┐   │                            │
│  │  │  OpenTelemetryCollector CR   │   │                            │
│  │  │  (define your own pipelines) │──┼──► CloudWatch Logs (EMF)   │
│  │  │                              │   │    CloudWatch Metrics      │
│  │  │  receivers:  otlp / prometheus│   │    AWS X-Ray (traces)     │
│  │  │  exporters:  awsemf / xray   │   │                            │
│  │  └──────────────────────────────┘   │                            │
│  └─────────────────────────────────────┘                            │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Feature Flags

| Variable | Default | Description |
|---|---|---|
| `enable_cloudwatch_observability` | `true` | EKS addon: Container Insights + FluentBit |
| `enable_adot` | `true` | EKS addon: AWS Distro for OpenTelemetry |
| `cloudwatch_log_retention_days` | `30` | Log retention for Container Insights log groups (0 = never expire) |

---

## IRSA Permissions

| Service Account | Namespace | Permissions |
|---|---|---|
| `orchestration` | `camunda` | S3 read/write |
| `optimize` | `camunda` | S3 read/write |
| `aws-load-balancer-controller` | `kube-system` | ELB / EC2 describe + manage |
| `cloudwatch-agent` | `amazon-cloudwatch` | `cloudwatch:PutMetricData`, `logs:*`, `ec2:Describe*` |
| `adot-collector` | `opentelemetry-operator-system` | `cloudwatch:*`, `logs:*`, `xray:*` |

---

## Module Dependencies

This configuration references shared Terraform modules via relative paths. Ensure the following modules are available relative to this directory:

| Path | Purpose |
|---|---|
| `../modules/vpc` | VPC with public/private subnets |
| `../modules/eks` | EKS cluster and managed node group |
| `../modules/iam-irsa` | IRSA role creation |
| `../../../managed-services/s3` | S3 bucket for Camunda backups |

These modules are part of the broader [camunda-consulting](https://github.com/camunda-consulting) infrastructure repository.

---

## Requirements

| Tool | Minimum version |
|---|---|
| Terraform | >= 1.8.0 |
| AWS CLI | v2 |
| kubectl | compatible with your EKS version |
| helm | v3 |
| envsubst | GNU gettext |

---

## Configuration

1. Copy the example variables file:
   ```bash
   cp locals.example.tfvars locals.auto.tfvars
   ```

2. Edit `locals.auto.tfvars` — set `project_name`, `region`, `domain_name`, etc.

3. Toggle observability features as needed:
   ```hcl
   enable_cloudwatch_observability = true
   enable_adot                     = true
   cloudwatch_log_retention_days   = 30
   ```

---

## Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `project_name` | string | `"example"` | Name prefix for all resources |
| `environment` | string | `"dev"` | Deployment environment |
| `region` | string | `"eu-central-1"` | AWS region |
| `domain_name` | string | `"example.com"` | Base domain for ingress |
| `cert_email` | string | `"admin@example.com"` | Email for Let's Encrypt |
| `node_count` | number | `3` | Desired EKS node count |
| `min_nodes` | number | `3` | Minimum EKS node count |
| `max_nodes` | number | `8` | Maximum EKS node count |
| `machine_type` | string | `"m6i.xlarge"` | EC2 instance type |
| `disk_type` | string | `"gp3"` | EBS volume type |
| `disk_size_gb` | number | `64` | Root volume size (GB) |
| `eks_version` | string | `"1.31"` | Kubernetes version |
| `vpc_cidr` | string | `"10.0.0.0/16"` | VPC CIDR block |
| `grafana` | bool | `false` | Install kube-prometheus-stack |
| `enable_cloudwatch_observability` | bool | `true` | CloudWatch Observability addon |
| `enable_adot` | bool | `true` | ADOT addon |
| `cloudwatch_log_retention_days` | number | `30` | CW log group retention (days) |

---

## Startup

```bash
chmod +x startup-all.sh shutdown-all.sh
./startup-all.sh
```

The script:
1. Runs `terraform init && terraform apply`
2. Updates kubeconfig
3. Installs **cert-manager** (required by the ADOT webhook)
4. Installs **ingress-nginx** (AWS NLB)
5. Creates a `letsencrypt-prod` ClusterIssuer
6. Applies the `gp3` StorageClass
7. Waits for the `amazon-cloudwatch-observability` and `adot` addons to reach `ACTIVE` state
8. Optionally installs the Grafana / Prometheus stack

### Using the ADOT Addon

After startup, define your OTEL pipelines using `OpenTelemetryCollector` custom resources. Example sidecar collector forwarding traces to X-Ray:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: xray-collector
  namespace: camunda
spec:
  mode: sidecar
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
    exporters:
      awsxray:
        region: <YOUR_REGION>
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [awsxray]
```

---

## Shutdown

```bash
./shutdown-all.sh
```

Removes ingress-nginx (cleans up the NLB) then runs `terraform destroy`.

---

## Troubleshooting

**ADOT addon stuck in `CREATING`**
The ADOT operator installs a mutating webhook that requires cert-manager. Ensure cert-manager pods are healthy before the addon reaches `ACTIVE`:
```bash
kubectl get pods -n cert-manager
```

**CloudWatch metrics not appearing**
Check the CloudWatch agent DaemonSet:
```bash
kubectl get ds -n amazon-cloudwatch
kubectl logs -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent --tail=50
```

**FluentBit logs not appearing**
Check the FluentBit DaemonSet included with the `amazon-cloudwatch-observability` addon:
```bash
kubectl get ds -n amazon-cloudwatch
kubectl logs -n amazon-cloudwatch -l app.kubernetes.io/name=fluent-bit --tail=50
```

**Terraform destroy fails (EKS addons)**
The EKS addons are managed by Terraform. Run `terraform destroy` and Terraform will remove them in the correct order. If you need to remove addons manually first:
```bash
aws eks delete-addon --cluster-name <CLUSTER> --addon-name amazon-cloudwatch-observability
aws eks delete-addon --cluster-name <CLUSTER> --addon-name adot
```
