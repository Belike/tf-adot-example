# CloudWatch Alerts for Camunda 8.7 — Implementation Reference

Audit of every alert in `Metrics___Alerts_8_7_WIP.xlsx` against:
- The ADOT collector allowlist (`adot-otel-collector.yaml`)
- The `amazon-cloudwatch-observability` EKS addon (FluentBit logs + Container Insights metrics)
- Actual 8.7 Helm values (`8_7-values-pod-annotations.yaml`)

## What you already have

| Source | Provides | Where to find it |
|---|---|---|
| ADOT collector | Camunda Prometheus metrics → EMF | Namespace `ContainerInsights/Prometheus`, log group `${CW_LOG_GROUP_PROMETHEUS}` |
| `amazon-cloudwatch-observability` addon — FluentBit | All pod stdout/stderr → CW Logs | Log group `${CW_LOG_GROUP_APP}` (typically `/aws/containerinsights/<cluster>/application`) |
| `amazon-cloudwatch-observability` addon — Container Insights | K8s infra metrics | Namespace `ContainerInsights` |

Service labels actually emitted (per your 8.7 Helm values):

| Component | `Service` value | Port |
|---|---|---|
| Zeebe broker | `zeebe` | 9600 |
| Zeebe gateway | `zeebe-gateway` | 9600 |
| Operate | `operate` | 9600 |
| Tasklist | `tasklist` | 9600 |
| Optimize | `optimize` | 8092 |
| Connectors | `connectors` | 8080 |
| Identity | `identity` | 8082 |

These are the values to use in CloudWatch alarm dimension filters — **not** `camunda-platform`, which is the 8.8 unified label.

---

## Status changes from the previous audit

The Container Insights addon being installed unblocks 7 alerts that were previously gated:

| Alert | Was | Now |
|---|---|---|
| Job Worker error logs | ⬛ Needs log pipeline | ✅ Ready (FluentBit ships logs) |
| Job Worker WARN logs | ⬛ | ✅ Ready |
| Camunda apps WARN | ⬛ | ✅ Ready |
| Camunda apps ERROR | ⬛ | ✅ Ready |
| Pod restart burst | ⚪ Different source | ✅ Ready (Container Insights) |
| Pod CPU near/exceeding limit | ⚪ | ✅ Ready |
| Pod memory near/exceeding limit | ⚪ | ✅ Ready |

PVC alerts and Elasticsearch alerts are still source-dependent — see notes per alert below.

---

## Per-alert reference

Status legend:
- ✅ **Ready** — works against your current setup with the updated ADOT YAML and the addon
- 🟡 **Partial** — fundamental CloudWatch limitation; pragmatic substitute provided
- ⚪ **Different source** — needs a separate decision (Elasticsearch source, PVC observability mode)

All metric alarms use `Namespace=ContainerInsights/Prometheus` unless noted. Container Insights infra alarms use `Namespace=ContainerInsights`. Log alarms use the custom namespace you choose for the metric filter.

---

### 1. Pending Incidents — ✅ Ready

- **Metric:** `zeebe_pending_incidents_total` (gauge despite the `_total` suffix — Camunda docs describe it as "the number of currently pending incident, i.e. not resolved")
- **Dimensions:** `Namespace=camunda, Service=zeebe` (optionally `partition=<n>`)
- **Alarm:**
  ```
  Statistic            = Maximum
  Period               = 60
  EvaluationPeriods    = 5
  DatapointsToAlarm    = 5
  Threshold            = 0
  ComparisonOperator   = GreaterThanThreshold
  TreatMissingData     = notBreaching
  ```

---

### 2. Job Worker / Custom Connector Backlog — ✅ Ready

- **Metric:** `executor_queued_tasks`
- **Dimensions:** `Namespace=camunda, Service=connectors, name=zeebe_client_thread_pool` (or `Service=zeebe` for the broker's own thread pool)
- **Alarm:**
  ```
  Statistic            = Maximum
  Period               = 60
  EvaluationPeriods    = 20
  DatapointsToAlarm    = 20
  Threshold            = 40
  ComparisonOperator   = GreaterThanOrEqualToThreshold
  ```
- The updated YAML's dedicated executor block carries `name` as a dimension so this filter works.

---

### 3. Job Worker / Custom Connector logs ERROR — ✅ Ready

- **Source:** pod stdout/stderr → FluentBit → `${CW_LOG_GROUP_APP}`
- **Metric Filter (one-time setup):**
  ```
  Filter pattern: ?ERROR ?Error ?error
  Log group:      /aws/containerinsights/<cluster>/application
  Metric:
    Namespace:   Camunda/Logs
    Name:        ConnectorErrorLogs
    Value:       1
    Default:     0
  ```
- **Alarm:**
  ```
  Statistic            = Sum
  Period               = 300
  EvaluationPeriods    = 1
  Threshold            = 0
  ComparisonOperator   = GreaterThanThreshold
  TreatMissingData     = notBreaching
  ```
- **Per-component scoping:** to alarm only on connector pod errors, use a JSON filter:
  ```
  { $.kubernetes.labels.app_kubernetes_io_name = "connectors" && $.log = %ERROR% }
  ```
  This requires FluentBit to ship logs as JSON with the `kubernetes` metadata block, which is the addon's default.

---

### 4. Job Worker / Custom Connector logs WARN — ✅ Ready

- Same shape as alert 3, with `?WARN ?Warn ?warn` and a separate metric (`ConnectorWarnLogs`).

---

### 5. Zeebe Unhealthy — ✅ Ready

- **Metric:** `zeebe_health`
- **Dimensions:** `Namespace=camunda, Service=zeebe, partition=<n>`
- **Verify enum first:**
  ```bash
  kubectl exec -n camunda zeebe-0 -- curl -s localhost:9600/actuator/prometheus | grep '^zeebe_health'
  ```
  Confirm whether 0 or 1 means HEALTHY in your specific 8.7 build before writing the operator.
- **Alarm (assuming HEALTHY=0):**
  ```
  Statistic            = Maximum
  Period               = 60
  EvaluationPeriods    = 5
  DatapointsToAlarm    = 5
  Threshold            = 0
  ComparisonOperator   = GreaterThanThreshold
  TreatMissingData     = breaching
  ```
- **Cold-start guard:** for the "Ready ≥10m" condition, build a Composite Alarm: this metric alarm AND a `pod_status_ready=1` alarm (Container Insights metric) over a 10-minute window.

---

### 6. Exporter Status != Exporting — ✅ Ready

- **Metric:** `zeebe_exporter_state`
- **Dimensions:** `Namespace=camunda, Service=zeebe, partition=<n>`
- **Value semantics:** `0=EXPORTING, 1=PAUSED, 2=SOFT_PAUSED, 3=CLOSED`
- **Alarm:**
  ```
  Statistic            = Maximum
  Period               = 60
  EvaluationPeriods    = 5
  Threshold            = 0
  ComparisonOperator   = GreaterThanThreshold
  ```

---

### 7. Elasticsearch Shards — ⚪ Different source

Your Helm values have `elasticsearch.enabled: true` (single master, in-cluster). So this is **self-managed** Elasticsearch, not OpenSearch Service.

Two paths:
- **(a) Add an `elasticsearch_exporter` deployment** as a sidecar or standalone scrape target, and add `^elasticsearch_.*$` to the ADOT allowlist. Then alarm on `elasticsearch_cluster_health_active_shards / (elasticsearch_cluster_health_number_of_data_nodes * 1000)` via metric math.
- **(b) Skip in non-prod** — your single-master setup is non-prod sized anyway; the shard-per-node ratio matters most at scale.

I'd skip for the demo cluster and revisit if you move to multi-node ES or migrate to OpenSearch Service.

---

### 8. Stream processor latency (p95) high — 🟡 Partial (true p95 not feasible)

- **Why partial:** CloudWatch percentiles can't be computed from Prometheus `_bucket` counters.
- **Available metrics:** `zeebe_stream_processor_latency_max`, `_sum`, `_count`
- **Option A — alarm on max (conservative):**
  ```
  Metric               = zeebe_stream_processor_latency_max
  Dimensions           = Namespace=camunda, Service=zeebe
  Statistic            = Maximum
  Period               = 300
  EvaluationPeriods    = 1
  Threshold            = <your SLO seconds>
  ```
- **Option B — average via metric math:**
  ```
  m1 = zeebe_stream_processor_latency_sum
  m2 = zeebe_stream_processor_latency_count
  e1 = RATE(m1) / RATE(m2)
  ```

---

### 9. Connectors job worker backlog — ✅ Ready

- Same as alert 2, scope to `Service=connectors`.

---

### 10. Camunda apps WARN — ✅ Ready

- Same shape as alert 4 with broader log-group scope. Pattern `?WARN`. Optionally split per Service via JSON path filter on `$.kubernetes.labels.app_kubernetes_io_name`.

---

### 11. Camunda apps ERROR — ✅ Ready

- Same shape as alert 3 with `?ERROR`. High-priority routing.

---

### 12. Operate Import Lagging Behind — ✅ Ready

- **Metrics:** `operate_import_time_seconds_sum`, `operate_import_time_seconds_count`
- **Dimensions:** `Namespace=camunda, Service=operate`
- **Alarm (metric math):**
  ```
  m1 = operate_import_time_seconds_sum
  m2 = operate_import_time_seconds_count
  e1 = RATE(m1) / RATE(m2)
  Statistic on e1      = Average
  Period               = 300
  EvaluationPeriods    = 6              # 30 minutes
  Threshold            = 900
  ComparisonOperator   = GreaterThanThreshold
  ```
- The updated ADOT YAML adds `^operate_.*$` to the allowlist.

---

### 13. Tasklist Import Lagging Behind — ✅ Ready

- Same as alert 12 with `tasklist_import_time_seconds_*` and `Service=tasklist`. `EvaluationPeriods=12` (1 hour) per spreadsheet.

---

### 14. Optimize Import Lagging Behind — ✅ Ready

- Same as alert 12 with `optimize_import_overallImportTime_seconds_*` and `Service=optimize`. `EvaluationPeriods=12` (1 hour).

---

### 15. Zeebe Exporter Lagging Behind — ✅ Ready

- **Metrics:** `zeebe_log_appender_last_committed_position`, `zeebe_exporter_last_exported_position`
- **Dimensions:** `Namespace=camunda, Service=zeebe, partition=<n>`
- **Alarm (metric math):**
  ```
  m1 = zeebe_log_appender_last_committed_position
  m2 = zeebe_exporter_last_exported_position
  e1 = m1 - m2
  Statistic on e1      = Maximum
  Period               = 300
  EvaluationPeriods    = 12             # 1 hour
  Threshold            = 1000000
  ```

---

### 16. Unbalanced Cluster — ✅ Ready

- **Metric:** `atomix_role`
- **Dimensions:** `Namespace=camunda, Service=zeebe, PodName=<pod>, partition=<n>` (now available via the new overlay block)
- **Verify enum first:**
  ```bash
  kubectl exec -n camunda zeebe-0 -- curl -s localhost:9600/actuator/prometheus | grep '^atomix_role'
  ```
- **Alarm — leader spread (assuming LEADER=3):**
  ```
  m1 = atomix_role  (per-partition, per-PodName)
  e1 = IF(m1 == 3, 1, 0)
  e2 = aggregated by PodName via SEARCH expression: MAX(per-pod) - MIN(per-pod)
  Threshold            = 2
  EvaluationPeriods    = 1
  Period               = 3600
  ```

---

### 17. Backup Failed — ✅ Ready

- **Metric:** `zeebe_backup_operations_total`
- **Dimensions:** `Namespace=camunda, Service=zeebe, partition=<n>, operation=status, result=<failed|completed>` (now available via the new overlay block)
- **Alarm (metric math):**
  ```
  m1 = zeebe_backup_operations_total {operation=status, result=failed}
  m2 = zeebe_backup_operations_total {operation=status, result=completed}
  e1 = RATE(m1) - RATE(m2)
  Statistic on e1      = Sum
  Period               = 900           # 15 minutes
  EvaluationPeriods    = 1
  Threshold            = 0
  ComparisonOperator   = GreaterThanThreshold
  ```

---

### 18. Elasticsearch Unhealthy (yellow) — ⚪ Different source

- Self-managed in-cluster ES per your Helm values. Same path as alert 7 — add `elasticsearch_exporter` and `^elasticsearch_.*$` to the allowlist. The relevant metric would be `elasticsearch_cluster_health_status` with `color` as a dimension.
- For the demo single-master cluster, status will be permanently `yellow` because there are no replicas to assign — this alarm would be a constant false-positive in your current setup. Skip until ES has ≥2 nodes.

---

### 19. Elasticsearch Unhealthy (red) — ⚪ Different source

- Same as alert 18 with `color=red`. Worth setting up even on the demo cluster because red means data unavailable, not just under-replicated.

---

### 20. Pod restart burst — ✅ Ready

- **Metric:** `pod_number_of_container_restarts` (Container Insights)
- **Namespace:** `ContainerInsights`
- **Dimensions:** `PodName, Namespace, ClusterName`
- **Alarm:**
  ```
  Statistic            = Maximum
  Period               = 300
  EvaluationPeriods    = 1
  Threshold            = 5
  ComparisonOperator   = GreaterThanThreshold
  ```
- Scope by `Namespace=camunda` to ignore restarts in other namespaces.

---

### 21. Pod CPU near/exceeding limit — ✅ Ready

- **Metric:** `pod_cpu_utilization_over_pod_limit` (Container Insights)
- **Namespace:** `ContainerInsights`
- **Alarm:**
  ```
  Statistic            = Average
  Period               = 300
  EvaluationPeriods    = 6              # 30 minutes
  Threshold            = 90
  ComparisonOperator   = GreaterThanThreshold
  ```

---

### 22. Pod memory near/exceeding limit — ✅ Ready

- Same as alert 21 with `pod_memory_utilization_over_pod_limit`, threshold 85, `EvaluationPeriods=12` (60 minutes).

---

### 23. Zeebe PVC capacity ≥80% — ⚪ Needs decision

The `amazon-cloudwatch-observability` addon's "enhanced container insights" mode publishes some volume-level metrics, but PVC-level utilization (filtered by name pattern) is not consistently available in the default Container Insights metric set. Three options:

- **(a) Enable enhanced Container Insights** in the addon configuration and check whether `pod_volume_used_percent` (or similar) appears in the `ContainerInsights` namespace. Quickest if it works.
- **(b) Add kubelet to the ADOT scrape config** with bearer-token auth and `^kubelet_volume_stats_.*$` allowlist with `[Namespace, persistentvolumeclaim]` dimensions. Most reliable. Requires extra collector RBAC for `nodes/proxy` and `nodes/metrics`.
- **(c) Skip for the demo cluster** — single-replica Zeebe with 10Gi PVC is small enough to monitor manually.

If you go with option (b):
```
m1 = kubelet_volume_stats_used_bytes
m2 = kubelet_volume_stats_capacity_bytes
e1 = m1 / m2
Filter on dimension persistentvolumeclaim ~ ".*zeebe.*"
Threshold = 0.8
EvaluationPeriods = 2
```

---

### 24. Zeebe PVC capacity ≥95% — ⚪ Needs decision

- Same as alert 23 with `Threshold=0.95`, `EvaluationPeriods=1`.

---

### 25. Elasticsearch PVC capacity ≥80% — ⚪ Needs decision

- Same options as alert 23 with PVC pattern `.*elasticsearch.*`.

---

### 26. Elasticsearch PVC capacity ≥95% — ⚪ Needs decision

- Same as alert 25 with `Threshold=0.95`.

---

## Summary

| Status | Count | Notes |
|---|---|---|
| ✅ Ready | 18 | Includes 7 newly unblocked by the Container Insights addon and 7 unblocked by the updated ADOT YAML |
| 🟡 Partial | 1 | Stream processor latency p95 — fundamental CW limitation, use _max instead |
| ⚪ Source decision | 7 | 4 PVC alarms + 2 ES health + 1 ES shards |

To go from 18 ready → all 26: enable enhanced Container Insights or add kubelet scraping (4 PVC alarms), and decide whether to add `elasticsearch_exporter` to in-cluster ES (3 alarms) or accept they don't apply to a single-master demo setup.

---

## Sanity-check commands after applying the updated ADOT YAML

```bash
# Confirm Service labels are correct
kubectl get pods -n camunda -L app.kubernetes.io/name --no-headers | awk '{print $NF}' | sort -u
# Expected: connectors, identity, operate, optimize, tasklist, zeebe, zeebe-gateway

# Verify the new metrics are flowing (wait ~2 minutes after applying)
aws cloudwatch list-metrics --namespace ContainerInsights/Prometheus \
  --metric-name operate_import_time_seconds_count
aws cloudwatch list-metrics --namespace ContainerInsights/Prometheus \
  --metric-name executor_queued_tasks --dimensions Name=name,Value=zeebe_client_thread_pool
aws cloudwatch list-metrics --namespace ContainerInsights/Prometheus \
  --metric-name zeebe_backup_operations_total \
  --dimensions Name=operation,Value=status Name=result,Value=completed
aws cloudwatch list-metrics --namespace ContainerInsights/Prometheus \
  --metric-name atomix_role --dimensions Name=PodName,Value=zeebe-0

# Verify FluentBit is shipping pod logs
aws logs describe-log-streams \
  --log-group-name /aws/containerinsights/${CLUSTER_NAME}/application \
  --max-items 5

# Verify Container Insights metrics for infra alerts
aws cloudwatch list-metrics --namespace ContainerInsights \
  --metric-name pod_cpu_utilization_over_pod_limit \
  --dimensions Name=Namespace,Value=camunda
```

If `operate_import_time_seconds_count` doesn't appear after 5 minutes, check the Operate pod has `prometheus.io/scrape: "true"` (it does in your Helm values — verify it survived the actual rollout). If `executor_queued_tasks` appears but without the `name` dimension, the dedicated executor block didn't deploy — re-check the YAML diff.