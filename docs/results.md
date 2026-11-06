# Multi-Region HA Data Platform: Experimental Results & SLA Metrics

## 1. Test Environment & Configuration

- **Host Platform:** Ubuntu on WSL2 (Linux x86_64)
- **Deployment Topology:**
  - Region A: `minio-a` (`net-region-a`, `net-wan`)
  - Region B: `minio-b` (`net-region-b`, `net-wan`)
  - Global Layer: `global-proxy` (Nginx on `net-wan`, port 8000), `failover-controller` (Python daemon on Docker socket)
- **Replication Architecture:** Bidirectional MinIO Bucket Replication with versioning (`data-bucket`)
- **Default Replication Mode:** Asynchronous Replication (`--sync disable`) for low client write latency (~3.8ms). Synchronous Replication (`--sync enable`) is available as an alternative configuration option that guarantees zero data loss while the peer link is healthy.
- **Failover Threshold (N):** 3 consecutive failed probes
- **Health Probe Interval (I):** 1.0 second
- **Health Probe Timeout:** 0.5 seconds
- **Health Probe Endpoint:** `GET /minio/health/live` (HTTP 200 OK expected)

---

## 2. RTO (Recovery Time Objective) Analysis

### 2.1 Investigation of Initial Detection Latency & Probe Trace

In initial baseline testing (threshold N = 3, interval = 2.0s), detection latency was measured at 9.58s from the first failed probe. Probe tracing revealed that without an enforced socket connect timeout and static target IP, failed connection attempts took ~2.0s to 3.0s each. Across 3 consecutive failures, this accumulated to ~9.6 seconds.

**Remediation:**
1. Locked the primary target IP literal (`172.20.0.5`) in the failover controller, passing `Host: minio-a:9000`.
2. Enforced a strict 0.5s connection/read timeout per probe.
3. Tightened probe interval to 1.0s.

### 2.2 Mathematical Detection Model

With direct IP targeting and bounded timeouts, detection latency following a hard crash (`docker kill minio-a`) is strictly predictable:

- Probe 1: Starts within `[0, Interval]` of failure. Kernel returns `ConnectionRefusedError` in 0.24ms or times out in 0.5s.
- Probe 2: Starts after Sleep(Interval) = 1.0s. Times out after 0.5s.
- Probe 3: Starts after Sleep(Interval) = 1.0s. Times out after 0.5s.
- Detection Trigger: Occurs immediately upon the 3rd failure.

Theoretical Detection from First Failure:
- Best-case (immediate ConnectionRefused on Probe 1): `0.0s + 2 * 0.5s + 2 * 1.0s = 3.00 seconds`.
- Worst-case (timeout on all 3 probes): `3 * 0.5s + 2 * 1.0s = 3.50 seconds`.

### 2.3 Live Per-Probe Trace During Hard Crash (`kill-region.sh region-a`)

| Probe Index | Timestamp (Epoch) | Status | Duration (ms) | Error Type |
|---|---|---|---|---|
| 250 (Probe 1) | 1793872110.6688 | FAIL | 0.24 ms | ConnectionRefusedError |
| 251 (Probe 2) | 1793872111.6703 | FAIL | 500.96 ms | TimeoutError |
| 252 (Probe 3) | 1793872113.1716 | FAIL | 500.80 ms | TimeoutError |

**Recorded RTO Timestamps:**
- Failure Injected: `1793872110.5587`
- First Failed Probe: `1793872110.6688` (0.110s after kill)
- Failure Detected: `1793872113.6728`
- First Success via Proxy: `1793872114.0450`

**Measured Timings:**
- Detection Latency from First Fail: **3.0040 seconds** (Mode 1: instant ConnectionRefusedError).
- Detection Latency from Crash: **3.1141 seconds**.
- Switchover Time: **0.3721 seconds** (re-write Nginx upstream + Docker socket SIGHUP).
- Total RTO: **3.4862 seconds**.

### 2.4 Run-by-Run RTO Benchmark Table & Detection Mode Hypothesis

Across all 9 failover injection runs recorded across the platform (Phase 2 baseline, 5 clean benchmark trials, and 3 live rehearsals), failure detection falls into two observed timing patterns:

| Run # / Scenario | Detection from First Fail (s) | Switchover Duration (s) | Total RTO (s) | Mode |
|---|---|---|---|---|
| **Phase 2 Baseline** | 3.0040 | 0.3721 | 3.4862 | Mode 1 |
| **Clean Trial 1** | 3.5046 | 0.3711 | 4.9059 | Mode 2 |
| **Clean Trial 2** | 3.5036 | 0.3657 | 4.8570 | Mode 2 |
| **Clean Trial 3** | 3.5041 | 0.3714 | 4.8871 | Mode 2 |
| **Clean Trial 4** | 3.5041 | 0.3798 | 4.8730 | Mode 2 |
| **Clean Trial 5** | 3.5036 | 0.3608 | 4.8655 | Mode 2 |
| **Rehearsal 1 (Initial)** | 3.5050 | 0.0110 | 3.9370 | Mode 2 |
| **Rehearsal 2 (Mid-Stream)** | 3.0040 | 0.0210 | 3.3200 | Mode 1 |
| **Rehearsal 3 (Full Log)** | 3.0030 | 0.3600 | 3.4660 | Mode 1 |
| **Summary Across 9 Runs** | **Range: 3.003 s – 3.505 s** | **Range: 0.011 s – 0.380 s** | **Range: 3.32 s – 4.91 s** | **Mode 1: 3 runs<br>Mode 2: 6 runs** |

#### Detection Mode Hypothesis (Unproven)

The underlying cause for the two detection latencies (~3.0s vs. ~3.5s) is considered an **unproven hypothesis**:
1. **Mode 1 Hypothesis (3.0s Detection — 3 runs):**
   - Probe 1 hits the killed container's socket immediately after the kernel closes the port, receiving an instant `ConnectionRefusedError` (0.24ms) without waiting for a timeout. Probes 2 and 3 then hit their 0.5s timeout separated by 1.0s intervals: `0.0s + 1.0s + 0.5s + 1.0s + 0.5s = 3.00 seconds`.
2. **Mode 2 Hypothesis (3.5s Detection — 6 runs):**
   - Probe 1 was already in-flight or the socket dropped packets during container termination, causing all 3 probes to wait the full 0.5s probe timeout: `3 * 0.5s + 2 * 1.0s = 3.50 seconds`.

**Switchover Duration Analysis (~0.37s vs. ~0.011s):**
- In runs with an **active cross-region replica**, the controller executes `mc replicate rm local/data-bucket --all --force` via the Docker Engine API to demote Region B to standalone mode. The time spent by `mc` initializing, authenticating, and persisting updated metadata on disk (~0.36s to 0.38s) is considered the **likely cause (not proven)** for the ~0.37s switchover.
- In runs where Region B was **already standalone**, `mc replicate rm` returned immediately, yielding **~0.011s – 0.021s** switchover (solely Nginx template re-write and SIGHUP reload).

### 2.5 Client-Visible Outage Gap (6.03s) vs. Controller RTO (3.47s)

In the full-stream rehearsal, the controller recorded a total failover RTO of **3.466s** (detection: 3.107s, switchover: 0.360s). However, the client-visible gap between successful writes in `writer.log` was **6.03 seconds** (last success on A at `10:43:22Z`, first success on B at `10:43:28Z`).

This delta occurs because in-flight write `obj-00006` started right at the moment of container crash (`10:43:23Z`) and was held for **4,365.5 ms** before returning `HTTP 502 Bad Gateway`:
- **Nginx Upstream Hold Configuration:**
  In `config/global/nginx.conf.template`:
  ```nginx
  resolver 127.0.0.11 valid=2s ipv6=off;
  set $backend_upstream http://${BACKEND_HOST}:${BACKEND_PORT};
  location / {
      proxy_pass $backend_upstream;
      proxy_connect_timeout 1s;
      proxy_read_timeout 30s;
      proxy_send_timeout 30s;
  }
  ```
- **Hold Mechanism (Likely, Untested):** Using a dynamic variable `$backend_upstream` forces Nginx to query the Docker internal DNS resolver `127.0.0.11` on every request according to the `valid=2s` TTL. When `minio-a` crashes, DNS resolution attempts, combined with `proxy_connect_timeout 1s` and upstream connection retry cycles, is considered a **likely, untested** explanation for the ~4.4s hold before generating a `502 Bad Gateway`. Crucially, in write #6, the 502 returned after the upstream configuration had already been repointed to Region B and reloaded, which the DNS/connect-timeout explanation does not fully account for. Once the 502 returned to the client, the next write (`obj-00007`) succeeded immediately on Region B with 3.7ms latency.

### 2.6 Startup Stall Investigation & Per-Step Trace

- **Correction on Earlier Claim:** In an earlier run, `docker wait minio-provision` appeared to eliminate the ~4s stall. However, in the subsequent full rehearsal, writes #2 (`10:43:16Z`) and #3 (`10:43:20Z`) were spaced ~4 seconds apart despite `docker wait minio-provision`. Because the logged curl latency for write #3 was only **7.6 ms**, the delay was conclusively **not a request blocked on a server-side metadata lock**.
- **Per-Step Instrumentation:** `scripts/demo/writer.sh` was instrumented with microsecond timestamps (`$EPOCHREALTIME`) around each loop phase (variable preparation, curl execution, awk parsing, log append, and sleep duration) and evaluated under two controlled environments:
  1. **Run (a) — Idle Stack with No Reconciler:** All 8 writes executed at steady ~1.01s – 1.02s intervals (loop duration ~1020ms; sleep=1001ms, curl=7-17ms, parse=4-7ms). No stall observed.
  2. **Run (b) — Stack Right After Starting Reconciler:** All 8 writes executed at steady ~1.02s – 1.03s intervals. No stall observed.
- **Conclusion:** The stall occurred in 3 runs immediately after a fresh `docker compose up`; it was not reproduced on a warm, instrumented stack (which does not recreate those conditions); **cause undetermined**.

---

## 3. Real RPO & Replication Mode Comparison

### 3.1 Pre-Restart RPO Methodology (`scripts/demo/rpo-check.sh`)

To measure true RPO without masking data loss via post-recovery replication:
1. Client writer streams numbered objects through the global proxy (`http://localhost:8000`).
2. Region A is terminated abruptly via SIGKILL (`kill-region.sh region-a`).
3. The failover controller switches traffic to Region B.
4. The writer is stopped.
5. **Before restarting Region A**, `scripts/demo/rpo-check.sh` compares the list of objects that returned HTTP 200 in `writer.log` against the objects actually present on surviving Region B. Any acknowledged write missing on Region B represents true RPO data loss.

### 3.2 Observed In-Doubt Writes (obj-00004) & Baseline Audits

- **Baseline Artifacts:** In initial baseline tests, surviving objects on Region B were observed to exceed client-acknowledged writes by 3 objects (`curl-test.txt`, `partition-test-obj.txt`, `proxy-test.txt`) due to leftover test artifacts from initial smoke tests. Complete bucket resets were added between trials to guarantee clean baseline states.
- **Observed In-Doubt Write (`obj-00004.txt`):** In our direct sync replication trials bypassing Nginx with a 60-second client timeout, write `obj-00004.txt` timed out at the client after 65.9 seconds. Upon inspecting Region A after restart, `obj-00004.txt` was found persisted on Region A's disk, despite the client observing a timeout failure. This confirms an **observed in-doubt write** state: MinIO committed the object to local storage before or during the remote replication call while the remote peer was unreachable.

### 3.3 Replication Tradeoff Analysis (Baseline Network)

| Metric | Asynchronous Replication (`--sync disable`) | Synchronous Replication (`--sync enable`) |
|---|---|---|
| **Client PUT Latency** | **3.8 ms** (range: 3.1ms - 4.6ms) | **9.0 ms** (range: 7.2ms - 11.5ms) (~2.4x latency) |
| **Write Confirmation** | HTTP 200 returned upon local write to primary | HTTP 200 returned after secondary confirms, until peer timeout trips |
| **Measured Baseline RPO (Normal WAN)** | **0 missing objects** (local bridge network replication lag < 80ms) | **0 missing objects** (peer reachable and healthy) |
| **RPO Exposure Window** | Vulnerable to loss of writes in-flight during replication backlog | Zero exposure while peer is online; vulnerable after peer link degradation |
| **Network Partition Impact** | Primary continues accepting writes; queues for resync | First write hangs ~65s; then silently degrades to local-ack HTTP 200 |

---

## 4. Lag-Injection Chaos Scenario (Active WAN Partition Followed by Crash)

To rigorously test RPO limits and stranded write behavior, lag-injection tests were executed:
1. `minio-b` was severed from `net-wan` (`docker network disconnect net-wan minio-b`).
2. The client streamed writes to `minio-a` through the global proxy.
3. Region A was crashed abruptly via SIGKILL (`docker kill minio-a`).
4. `minio-b` was reconnected to `net-wan`, and failover completed.
5. The writer was stopped, and `scripts/demo/rpo-check.sh` was executed **before restarting Region A**.

### 4.1 Async Stranded Writes Audit: Exact Object Names & Versioning Accounting

In the async lag-injection scenario, 14 writes were streamed during the WAN partition, followed by crashing Region A and failing over to Region B:

- **(a) Objects Acknowledged by Client (19 objects):**
  `obj-00001.txt`, `obj-00002.txt`, `obj-00003.txt`, `obj-00004.txt`, `obj-00005.txt`, `obj-00006.txt`, `obj-00007.txt`, `obj-00008.txt`, `obj-00009.txt`, `obj-00010.txt`, `obj-00011.txt`, `obj-00012.txt`, `obj-00013.txt`, `obj-00014.txt`, `obj-00015.txt`, `obj-00016.txt`, `obj-00017.txt`, `obj-00018.txt`, `obj-00019.txt`
- **(b) Objects on Region B Right After Failover (5 objects):**
  `obj-00015.txt`, `obj-00016.txt`, `obj-00017.txt`, `obj-00018.txt`, `obj-00019.txt`
- **(c) Exact Acked-but-Missing Objects (14 objects):**
  `obj-00001.txt`, `obj-00002.txt`, `obj-00003.txt`, `obj-00004.txt`, `obj-00005.txt`, `obj-00006.txt`, `obj-00007.txt`, `obj-00008.txt`, `obj-00009.txt`, `obj-00010.txt`, `obj-00011.txt`, `obj-00012.txt`, `obj-00013.txt`, `obj-00014.txt`
- **(d) Names on Region B After Resync A -> B (19 objects):**
  `obj-00001.txt`, `obj-00002.txt`, `obj-00003.txt`, `obj-00004.txt`, `obj-00005.txt`, `obj-00006.txt`, `obj-00007.txt`, `obj-00008.txt`, `obj-00009.txt`, `obj-00010.txt`, `obj-00011.txt`, `obj-00012.txt`, `obj-00013.txt`, `obj-00014.txt`, `obj-00015.txt`, `obj-00016.txt`, `obj-00017.txt`, `obj-00018.txt`, `obj-00019.txt`

**Accounting Explanation (Resync "27 objects" vs. Audit 22/22):**
MinIO buckets with versioning enabled record a `DeleteMarker` entry for every deleted object whenever `mc rm` is run without `--versions`. When `mc replicate resync` runs, it audits and replicates all version entries (including delete markers and prior version metadata). In earlier testing, 5 objects were deleted without `--versions`, leaving behind 5 delete markers plus 22 live objects, resulting in 27 total versioned records synchronized by `mc replicate resync`. In contrast, `mc ls` only displays live, non-deleted objects (22 objects).

### 4.2 Direct Synchronous Mode Mid-Stream Partition Test (Bypassing Nginx, 60s Timeout)

To observe MinIO's native synchronous replication behavior without proxy timeout truncation, writes were issued directly to `minio-a` (`http://localhost:9001/data-bucket/`) with a 60-second client timeout:
1. Stream initial writes mid-stream while peer is healthy.
2. Partition `minio-b` from `net-wan` while writing continues.
3. Abruptly kill `minio-a` via SIGKILL.
4. Run `rpo-check` before restarting `minio-a`.
5. Restart `minio-a` and audit ambiguous / in-doubt writes.

| Trial # | Pre-Partition Writes (`obj-00001` - `obj-00003`) | Post-Partition Write #4 (`obj-00004`) | Post-Partition Write #5 (`obj-00005`) | Pre-Restart RPO Audit: Acked vs Present on B | Acked but Missing (RPO) | Ambiguous Writes on A After Restart |
|---|---|---|---|---|---|---|
| **Trial 1** | 3/3 HTTP 200 (~6.3ms - 21.5ms), on B | TimeoutError (65,921.3 ms) | HTTP 200 (4.2 ms) | Acked: 4 (`obj-1,2,3,5`) vs B: 3 (`obj-1,2,3`) | **1 object lost (`obj-00005.txt`)** | `obj-00004.txt` on A (timed out at client) |
| **Trial 2** | 3/3 HTTP 200 (~5.6ms - 7.2ms), on B | TimeoutError (65,922.4 ms) | HTTP 200 (5,297.7 ms) | Acked: 4 (`obj-1,2,3,5`) vs B: 3 (`obj-1,2,3`) | **1 object lost (`obj-00005.txt`)** | `obj-00004.txt` on A (timed out at client) |
| **Trial 3** | 3/3 HTTP 200 (~5.0ms - 6.0ms), on B | TimeoutError (65,918.4 ms) | HTTP 200 (7.5 ms) | Acked: 4 (`obj-1,2,3,5`) vs B: 3 (`obj-1,2,3`) | **1 object lost (`obj-00005.txt`)** | `obj-00004.txt` on A (timed out at client) |

### 4.3 Detailed Analysis: Does Synchronous Mode Ever Ack a Write the Peer Doesn't Have?

**YES.** MinIO synchronous replication does **not** indefinitely enforce synchronous replica confirmation under sustained network partitions:

1. **Observed Hang-Then-Fast-Ack Behavior:**
   When the remote peer was partitioned, the first write (`obj-00004.txt`) hung for ~65.9 seconds before the client timed out. Immediately following this timeout, the next write (`obj-00005.txt`) returned HTTP 200 in 4.2ms to 7.5ms.
2. **Replication Health-Check Mechanism (Likely Explanation, Not Proven):**
   MinIO's internal replication health-check marking the remote peer as degraded/offline after the connection timeout is the **likely explanation (unproven)** for why MinIO ceased blocking on the remote peer and silently fell back to local-only acknowledgement.
3. **Timeout Behavior Under Partition (Client Returned at ~66s Despite 60s Timeout; Cause Undetermined):**
   In our direct PUT benchmark with a 60s client socket timeout, the client returned at ~65.9s despite the 60s timeout; cause undetermined. Direct verification using `curl --max-time 60 -w '%{time_total}'` against `minio-a` during an active partition returned at 60.08s with exit code 28 (`CURLE_OPERATION_TIMEDOUT`). In both cases, the client observed a timeout without receiving an HTTP acknowledgement, while MinIO committed the object locally to Region A.
4. **Observed In-Doubt Write (`obj-00004.txt`):**
   Even though the client observed a timeout failure, MinIO committed `obj-00004.txt` locally to disk on Region A with `Replication Status: COMPLETED` on A.
5. **Data Missing on Region B at Failover (RPO > 0):**
   Because `obj-00005.txt` returned HTTP 200 to the client but existed only on Region A, when Region A crashed and traffic failed over to Region B, `obj-00005.txt` was missing on Region B. This write was missing from region B at failover; recoverable only if region A's disk survives (RPO = 1).

### 4.4 Exact Conditions for Synchronous Zero Data Loss Guarantees

- **When Synchronous Mode Guarantees Zero Data Loss (RPO = 0):**
  Synchronous mode guarantees zero data loss **only while the remote replication peer is healthy and reachable**. During normal operation, HTTP 200 is returned only after both nodes acknowledge receipt.
- **When Synchronous Mode Does NOT Guarantee Zero Loss:**
  - **Degraded Replication Link:** Once the peer is partitioned for longer than MinIO's internal connection timeout (~65s), MinIO marks the peer offline and silently returns HTTP 200 for local writes without waiting for the replica. If the primary crashes before the link heals and queues are resynced, those acknowledged writes are missing from region B at failover; recoverable only if region A's disk survives.
  - **Observed In-Doubt Writes:** Writes that time out at the client during the ~65s timeout window may still be committed locally to the primary node. If the primary crashes, the client believes the write failed, but the data remains on the primary's disk.
  - **Failover Demotion:** Automated failover strips the surviving node's replication rule to prevent traffic stalls; during a false-positive failover, nodes accept independent writes and diverge until manual reconciliation.

---

## 5. Disaster Recovery & Failback Eventual Consistency

Failback is intentionally manual (`scripts/chaos/failback.sh`) to prevent flapping and split-brain:

1. **Service Recovery:** Starts `minio-a` and reconnects `net-wan`.
2. **Stranded Writes & Replication Backlog:** When `minio-a` restarts after an abrupt SIGKILL crash during an async partition, stranded objects on Region A do not automatically replicate to Region B on their own. Dropping volatile in-memory replication queues during SIGKILL is considered the **likely cause unless proven otherwise**.
3. **Bidirectional Resync Execution:** `scripts/chaos/failback.sh` executes resync in **both directions**:
   - **Direction A -> B:** `docker exec minio-a mc replicate resync start local/data-bucket --remote-bucket <ARN_A>` (backfills stranded partition writes to Region B).
   - **Direction B -> A:** `docker exec minio-b mc replicate resync start local/data-bucket --remote-bucket <ARN_B>` (backfills failover writes to Region A).
4. **Drain Verification:** Confirms `queued.count == 0` and `resync status` reports `Status: Completed` with `Failed: 0` on both nodes.
5. **Traffic Handover:** Updates Nginx upstream back to `minio-a:9000` via Docker Engine API and reloads configuration.
6. **Eventual Consistency Audit:** `scripts/demo/verify.sh` confirmed:
   - Region A Total Objects: 71
   - Region B Total Objects: 71
   - Synchronized Objects: 71
   - Out-of-Sync Discrepancy: 0 objects (**100% Eventual Consistency Achieved**).

---

## 6. Known Limitations

1. **Sync Replication Degrades After Peer Timeout:** If a network partition exceeds MinIO's internal replication timeout (~65s), MinIO marks the peer offline and silently falls back to local-only acknowledgement. If the primary crashes before the partition heals, acknowledged writes are missing from Region B at failover; recoverable only if Region A's disk survives.
2. **False-Positive Failover Divergence:** On automated failover, the controller strips Region B's replication rule so writes succeed unblocked. If a false-positive failover occurs while Region A is still active, both regions accept writes independently and diverge until manual failback.
3. **Container User Permissions (Root Containers):** Containers run as `user: "0:0"` (root) as an intentional development workaround to prevent host bind-mount permission conflicts across Linux/WSL environments.
4. **Docker Socket Access:** The failover controller container mounts `/var/run/docker.sock` to issue SIGHUP reloads directly via the Docker Engine API.
5. **Single-Machine Simulation:** Both fault domains, the WAN bridge network, the edge proxy, and the controller run on a single host machine across Docker bridge networks.
