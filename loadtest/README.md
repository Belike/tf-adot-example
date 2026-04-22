# Generic Camunda 8.8 Load Test

Generic benchmark assets for validating a Camunda 8.8 deployment against your
existing CloudWatch dashboard. No customer-specific names, processes, or
payload fields.

## Deployment target

- Values file: `8.8-values-pod-annotations.yaml` (full stack: Optimize,
  Connectors, WebModeler, Keycloak + Postgres, Identity)
- Chart: `camunda/camunda-platform` version `13.4.1`
- Namespace: `camunda`
- OIDC client: `orchestration` with admin rights (handled out-of-band in Keycloak)

## Files

| File | Purpose |
|---|---|
| `assets/generic_benchmark_process.bpmn` | 5 service tasks + 1 XOR gateway, job type `benchmark-task` |
| `payload-configmap.yaml` | Generic ~1KB JSON payload with `branchKey` for the gateway |
| `benchmark.yaml` | Kubernetes Job running `camundacommunityhub/camunda-8-benchmark:main` |
| `deploy-camunda-assets.sh` | Deploys BPMN/DMN/form files via Orchestration REST API v2 |
| `start-benchmark.sh` | Orchestrates: helm install → rebalance → deploy assets → run 15 min → record timestamps |

## Load profile

- **Target rate**: 100 process instances/second (constant, no ramping)
- **Warmup**: 60 s
- **Duration**: 15 min (matches your previous runs)
- **Task completion delay**: 150 ms (matches your previous runs)
- **Max backpressure**: 10% (benchmark auto-adjusts below this)
- **Streaming**: enabled, gRPC preferred over REST

Expected steady-state (based on 5 service tasks × 100 PI/s at ~50% branch split):
- **Job completion rate**: ~500 jobs/s (5 tasks × 100 PI/s, one gateway branch adds one task)
- **Flow node instance rate**: ~900–1100/s (5 tasks + gateway + start/end per PI)

> **Note**: This deployment has `partitionCount: 3` and `pvcSize: 10Gi` with
> no CPU/memory overrides — much smaller than a production-sized cluster. At
> 100 PI/s you may see backpressure kick in, which is a valid observation
> for dashboard validation.

## Usage

```bash
# 1. Prerequisites (you handle these before running):
#    - kubectl context points at the right EKS cluster
#    - 'camunda-credentials' secret exists in namespace 'camunda'
#    - 'orchestration' OIDC client has admin rights in Keycloak
#    - DNS/ingress wired up (normunda.de)
#    - StorageClass 'gp3' as default (storageclass.yaml)

# 2. Run everything:
./start-benchmark.sh

# Output includes start/end timestamps in both RFC3339 and epoch-ms for
# pasting into CloudWatch dashboard time pickers.
```

## CloudWatch dashboard validation

After the run, use the printed start/end timestamps to scope your dashboard
time window. Key validation points:

1. **Zeebe throughput** — `zeebe_stream_processor_records_total` (partition,
   recordType) should show ~500 jobs/s COMMAND + ~1000 events/s
2. **Backpressure** — `zeebe_broker_backpressure_total` should stay <10%
   (matches the benchmark's self-limiting setting)
3. **OpenSearch exporter lag** — `zeebe-record-*` indexing rate should match
   the record production rate
4. **Operate/Tasklist importer** — watch for growing `import-position` lag
   on under-sized clusters
5. **JVM** — orchestration pod heap should stabilize well below 14Gi limit
   (old test peaked ~12Gi; this smaller cluster should peak lower)

## Differences from previous customer runs

- Generic process ID: `GenericBenchmarkProcess` (was `SCC_Arcot_OTP`)
- 5 service tasks instead of 7
- 1 XOR gateway instead of 3 (driven by `branchKey` variable)
- No DMN tables (add later if decision evaluation throughput matters)
- Payload has no PII/customer fields
- Client secret now read from `camunda-credentials` secret at job runtime
  instead of being baked into `JAVA_OPTIONS`

## Known limitations

- `partitionCount: 3` in the values file means only 3 broker leaders can
  process commands in parallel. If you want to compare against 9-partition
  runs, create an overlay values file or bump the main file.
- The benchmark image (`camundacommunityhub/camunda-8-benchmark:main`) is
  built for stream-enabled gRPC; if your Zeebe gateway build disables
  streaming, set `stream-enabled=false` in `benchmark.yaml`.
