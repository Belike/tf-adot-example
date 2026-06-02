# Camunda 8.7 Dashboard Runbook

Operator reference for the Camunda 8.7 CloudWatch dashboard. For each section: what the panels mean, what abnormal looks like, first-line pointers, and the trigger to escalate to Camunda support.

> **Scope note.** The downstream search store is **OpenSearch**. Zeebe-side exporter symptoms (flush latency, failed flushes, bulk memory) are covered in §7 of this runbook. OpenSearch *cluster* health — node count, ingest performance, disk pressure — is on a separate OpenSearch dashboard and must be observed there; most exporter-side symptoms originate downstream.

## How to read this dashboard

- **Zeebe** is the workflow engine. Work is sharded across **partitions**; each partition has one leader and N followers. Default: 3 followers.
- A **stream processor** consumes the partition log and drives the workflow state machine.
- A **log appender** persists records and **commits** them once a quorum of replicas has acknowledged.
- **Exporters** push committed records to OpenSearch.
- The **gateway** is the client API (gRPC + REST). It routes to partition leaders; it does not process workflow data.
- Per-partition panels show one line per partition. 
- Per-component panels show one line per service (`zeebe`, `zeebe-gateway`, `operate`, `tasklist`, `optimize`, `connectors`, `identity`).

---

## 1. General Overview

| Panel | Shows                                                                                                          | Concerning                       |
|---|----------------------------------------------------------------------------------------------------------------|----------------------------------|
| Partition health (min) | Min `zeebe_health` across partitions. 1=healthy, 0=unhealthy                                                   | 0 for longer time                |
| Banned instances | Process instances Zeebe gave up on after repeated failures.                                                    | Any growth                       |
| Pending incidents | Instances stuck on a failure waiting for an operator. This is a business impact issue and often not technical. | Growing                          |
| Cluster change status | State of a topology change (add/remove broker, rebalance).                                                     | FAILED, or IN_PROGRESS for hours |
| Stream processor records (avg, per partition) | Avg of cumulative `zeebe_stream_processor_records_total` over 60 s per partition. Should grow monotonically; flatten = no processing. | One partition flatlines          |
| Exported events (avg, per partition) | Avg of cumulative `zeebe_exporter_events_total` over 60 s per partition. Should grow monotonically and track records. | Flatlines, or growth diverges downward from records |
| Records appended / min | Log appender writes per partition; should track records.                                                       | Drops with ingestion running     |

**Pointers**
- A flatlined partition → its leader is restarting, OOMing, or has lost leadership.
- Growing banned instances → an application-side issue is producing repeat failures; find the process in Operate.
- Pending growing without banned growing → engine is fine; surface to the workflow's business owner.
- Exported events flatlining while records keep growing → check the OpenSearch dashboard first; the exporter side here will only show *symptoms*.

**Escalate** if `zeebe_health` stays at 2 on any partition >5 min, cluster change reads FAILED, or banned instances jump by hundreds in one window with no obvious cause.

---

## 2. Backpressure & Stream Processor Latency

Zeebe's overload defense: the gateway rejects new requests rather than letting queues grow unbounded. This can be seen as a DoS prevention mechanism for process execution.

> **8.7 note.** 8.7 exposes `zeebe_backpressure_requests_limit` (gauge) and the stream-processor latency histogram.

| Panel | Shows | Concerning |
|---|---|---|
| Request limit (per partition) | Adaptive in-flight request ceiling; drops on overload. | Oscillating low values |
| Stream processor latency max | Time between record appended and stream processor handling it. | Multi-second spikes that don't recover |

**Pointers**
- Sustained low limit + high latency → broker is the bottleneck; cross-check CPU, disk I/O, and OpenSearch health.
- Latency spikes coinciding with snapshots → expected; should recover within a minute.

**Escalate** if the request limit stays collapsed after client traffic drops, or latency stays in tens of seconds for >10 min with no obvious resource constraint.

---

## 3. Processing — Positions

Positions are monotonically increasing record numbers. They should advance in lockstep:

**Appended ≥ Committed ≥ Processed ≥ Exported.** A widening gap tells you which stage is lagging.

| Panel | Shows | Concerning |
|---|---|---|
| Last appended | Newest record on local disk. | Flat = broker not writing |
| Last committed | Newest record durable on a quorum. | Flat behind appended = replication stalled |
| Last processed | Newest record handled by stream processor. | Flat behind committed = stream processor wedged |
| Last exported | Newest record handed off to the downstream exporter. | Lags processed significantly = exporter target behind |
| Processing duration max | Time to process a single record. | Sustained multi-second values |

**Escalate** if any position is stuck >10 min (especially appended or committed), or any position moves backwards (which should be impossible).

---

## 4. Throughput

Functional view of what's flowing through the engine.

| Panel | Shows | Concerning |
|---|---|---|
| PI events / min | Process-instance lifecycle events. | Drop to zero while clients are active |
| Element events / min | Element transitions. Always a multiple of PI rate. | Drops while PI events continue |
| Job events / min | Job lifecycle events. | `created` climbs while `completed` flatlines = workers backed up |
| Incident events / min | New incident rate. Annotated at 1/min. | Any sustained non-zero |
| PI execution time max | Longest active process instance. | Growing without bound |
| Pending incidents (per partition) | Per-partition breakout. | Concentration on one partition = poison message on that shard |

**Pointers**
- PI events drop, element events normal → clients can't start new instances; check backpressure and client logs and Zeebe logs.
- Job created and completed → workers slow or down; check worker/connector logs.
- Incident burst → usually application-side; find the BPMN element in Operate and review. Pause execution until resolved.

---

## 5. Log Appender — Latency & Commit Lag

Disk and replication health per partition.

| Panel | Shows | Concerning |
|---|---|---|
| Append latency max | Time to write one record locally. | Tens of ms = disk slow; hundreds = disk failing |
| Commit latency max | Append + quorum round-trip. | Hundreds of ms = network or follower problem |
| Commit lag (aggregate) | `appended − committed` cluster total. | Continuously growing |

**Pointers**
- High append latency → PVC IOPS / storage class undersized; cross-check Container Insights disk metrics.
- High commit, normal append → a follower is sick; find the lagging pod.
- Commit lag climbing → same root cause; cluster risks data loss on a leader crash if it doesn't recover.

**Escalate** if commit lag grows past hundreds of thousands of records, or append latency stays high after confirming disk isn't the bottleneck.

---

## 6. Snapshots

Periodic log compaction. Bounds disk usage and lets new followers catch up quickly.

| Panel | Shows | Concerning |
|---|---|---|
| Snapshot rate / min | Snapshots completing per partition. | Zero for hours under load |
| Snapshot duration max | Slowest snapshot in the window. | Tens of minutes — can starve processing |
| Snapshot size | Latest snapshot size per partition. | Unbounded growth |

**Pointers**
- No snapshots while throughput is normal → processed position isn't advancing; snapshots are gated on processing progress.
- Snapshot size ballooning → typically long-running instances or oversized variables; find instances in Operate.

---

## 7. Exporter — OpenSearch

Zeebe-side view of the OpenSearch exporter. Cluster-side problems on OpenSearch surface here first as flush slowness or failures, with bulk memory backing up.

| Panel | Shows | Concerning |
|---|---|---|
| OS exporter flush duration max | Time to flush a bulk to OpenSearch, per partition. | Sustained seconds = OS slow or back-pressured |
| OS exporter failed flushes / min | Bulk flush failures. Annotated at 1/min. | Any sustained non-zero |
| OS exporter bulk memory | Bytes buffered in pending bulks, per partition. | Continuously climbing = OS not draining |

**Pointers**
- Failed flushes > 0 → OpenSearch is unhealthy or rejecting writes; jump to the OpenSearch dashboard.
- Flush duration climbing with bulk memory climbing → OS ingest is the bottleneck; exported position (§3) will lag next.
- Bulk memory at zero and no flushes → exporter is idle (no records to export) or stuck; cross-check §3 last exported position.

**Escalate** if failed flushes persist after OpenSearch is confirmed healthy, or bulk memory grows unbounded with no OS-side cause.

---

## 8. Gateway, gRPC & REST API

Client-facing surface. Workers and connectors connect here:

| Panel                        | Shows | Concerning                                                                   |
|------------------------------|---|------------------------------------------------------------------------------|
| Gateway total requests / min | All gateway requests. | Drop while clients still trying                                              |
| gRPC requests received / min | Inbound gRPC stream messages. | Sudden drop                                                                  |
| gRPC responses sent / min    | Outbound; should mirror received. | Divergence = gateway can't respond                                           |
| Gateway request latency max  | Slowest gateway request. | Multi-second sustained                                                       |
| gRPC processing duration max | Slowest gRPC handler. | Multi-second sustained                                                       |
| HTTP active requests (sum/60s) | Sum of `http_server_requests_active_seconds_gcount` across Operate/Tasklist/Optimize/Identity/Connectors. Reflects in-flight HTTP requests. | Sudden drop = Check health of components                                     |
| Job stream - clients         | Workers holding job-stream connections. | Drop = workers disconnecting                                                 |
| Job stream - servers         | Broker-side endpoints serving job streams. | Drop = gateway lost a broker connection                                      |
| Job stream pushes / min      | Jobs pushed to streaming workers. | Zero while jobs are created = streaming broken, workers fall back to polling |

**Pointers**
- Gateway latency high, broker latency normal → gateway pod is the bottleneck; check its CPU/JVM (§9).

**Escalate** if gateway latency stays high after brokers are confirmed healthy, or if job streaming stops entirely.

---

## 9. Memory & JVM (per Component)

| Panel | Shows | Concerning |
|---|---|---|
| JVM heap used | Live heap per component. | Flatline near max = pre-OOM |
| JVM heap max | Configured max (from Helm values). | Sudden change = config drift |
| JVM buffer memory used | Off-heap I/O buffers. | Unbounded growth = native leak |
| JVM threads live | Total live threads. | Linear growth = thread leak |
| JVM threads daemon | Daemon-thread subset. | Linear growth = pool not releasing |
| JVM GC pause max | Worst stop-the-world pause. | >1s pauses on brokers cause backpressure |

**Pointers**
- Heap pinned high + GC pauses lengthening → pre-OOM; restart as stopgap, fix by raising heap or investigating workload growth.
- Thread count climbing without throughput climbing → code-level leak; capture a thread dump before restart.
- Buffer memory climbing → networking; check for stuck connections or undersized pool config.

**Escalate** if a broker's GC pauses repeatedly exceed a second, heap pressure persists after sizing has been adjusted per Camunda guidance, or you have a captured thread/buffer leak.

---

## 10. CPU & File Descriptors (per Component)

| Panel | Shows | Concerning |
|---|---|---|
| Process CPU usage | Fraction of allotted CPU in use. | Pinned at 1.0 |
| System load 1m | 1-min load average inside the container. | Sustained above CPU count = queueing |
| Open file descriptors | Per-component FD count. | Linear growth = FD leak |

**Pointers**
- CPU pinned, GC normal → JVM doing real work but undersized; resize or scale out.
- Load high, CPU normal → I/O wait; cross-check §5 latencies.
- FD count climbing forever → socket or file leak; capture state before restarting.

**Escalate** if an FD leak is reproducible and clearly inside Camunda code, or CPU saturation persists at sizing levels Camunda has previously validated for your throughput tier.

---

## 11. Aggregate Health (cluster-wide)

Two cluster totals as an at-a-glance "is anything moving?" check.

| Panel | Shows | Concerning |
|---|---|---|
| Stream processor records (avg, cluster total) | Avg of cumulative `zeebe_stream_processor_records_total` across partitions over 60 s. Should grow monotonically. | Flatlines while client traffic is steady |
| Exporter events (avg, cluster total) | Avg of cumulative `zeebe_exporter_events_total` across partitions over 60 s. Should grow monotonically and track records. | Growth diverges downward from records-total |

**Pointers**
- Records line flattens → at least one partition is stuck; go to §1 and §3.
- Exporter line falls behind records → check the OpenSearch dashboard (downstream ingest is the most common cause).

**Escalate** if both lines stop growing for an extended period with no deploy or expected lull in traffic.

---

## Appendix — Bundle to attach when opening a Camunda support ticket

- Camunda version (Helm chart version and image digests for the affected components).
- Cluster topology: broker count, partition count, replication factor, Helm values.
- Time range of the incident (UTC).
- Screenshot of the dashboard or links to affected panels at the incident time.
- Pod logs for the affected component(s) over the incident window.
- Actuator output if reachable: `/actuator/health`, `/actuator/prometheus`, `/actuator/configprops`.
- Recent partition/topology status (`zbctl status`).
- For data-path issues: OpenSearch cluster health, node count, free disk (from the OpenSearch dashboard / cluster).
- Anything that changed in the 24h before the incident: deploys, config changes, traffic shape.
