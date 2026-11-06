# Multi-Region HA Data Platform: Experimental Results & SLA Metrics

## 1. Test Environment & Configuration

- **Host Platform:** Ubuntu on WSL2 (Linux x86_64)
- **Deployment Topology:**
  - Region A: `minio-a` (`net-region-a`, `net-wan`)
  - Region B: `minio-b` (`net-region-b`, `net-wan`)
  - Global Layer: `global-proxy` (Nginx on `net-wan`, port 8000), `failover-controller` (Python daemon on Docker socket)
- **Replication Architecture:** Bidirectional MinIO Bucket Replication with versioning (`data-bucket`)
- **Default Replication Mode:** Asynchronous Replication (`--sync disable`) for low client write latency (~3.8ms). Synchronous Replication (`--sync enable`) is available as a zero-RPO configuration option.
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
- Failure Injected (T_failure): `1793872110.5587`
- First Failed Probe (T_first_fail): `1793872110.6688` (0.110s after kill)
- Failure Detected (T_detect): `1793872113.6728`
- First Success via Proxy (T_first_success): `1793872114.0450`

**Measured Timings:**
- Detection Latency from First Fail (T_detect - T_first_fail): **3.0040 seconds** (matches theoretical 3.00s model).
- Detection Latency from Crash (T_detect - T_failure): **3.1141 seconds**.
- Switchover Time (T_first_success - T_detect): **0.3721 seconds** (re-write Nginx upstream + Docker socket SIGHUP).
- Total RTO (T_first_success - T_failure): **3.4862 seconds**.

### 2.4 Writer Cadence & Startup Timing Note

- In standalone usage, `scripts/demo/writer.sh` defaults to a 1.0-second interval (`WRITER_INTERVAL=1.0`). In benchmark and chaos suites, the interval is overridden to fast-burst rates (e.g. `WRITER_INTERVAL=0.15` to `0.30s`). With curl execution latency (~4ms to 10ms), this yields an observed cadence of ~0.31s to 0.32s per write.
- A 3.903-second gap observed between writes #2 and #3 in one initial run is unexplained, not reproduced in subsequent runs. Curls for writes #2 and #3 completed in 9.6ms and 9.0ms respectively. Subsequent clean runs confirmed steady ~0.31s intervals across all writes.

---

## 3. Real RPO & Replication Mode Comparison

### 3.1 Pre-Restart RPO Methodology (`scripts/demo/rpo-check.sh`)

To measure true RPO without masking data loss via post-recovery replication:
1. Client writer streams numbered objects through the global proxy (`http://localhost:8000`).
2. Region A is terminated abruptly via SIGKILL (`kill-region.sh region-a`).
3. The failover controller switches traffic to Region B.
4. The writer is stopped.
5. **Before restarting Region A**, `scripts/demo/rpo-check.sh` compares the list of objects that returned HTTP 200 in `writer.log` against the objects actually present on surviving Region B. Any acknowledged write missing on Region B represents true RPO data loss.

### 3.2 Trial Inventory & Ambiguous Writes Analysis (Possible Scenario)

In earlier multi-trial tests, surviving objects on Region B were observed to exceed client-acknowledged writes by 3 objects:
- **Investigation:** Detailed inspection confirmed these 3 items were leftover test artifacts from earlier smoke tests (`curl-test.txt`, `partition-test-obj.txt`, `proxy-test.txt`), as earlier cleanup targeted only `obj-*`.
- **Ambiguous Writes (Possible Scenario):** In theory, when a crash occurs during request transit, writes that were processed by the primary and replicated to the secondary before the crash could return HTTP 502 Bad Gateway to the client if the connection was severed before HTTP 200 reached the client, yet still exist on the secondary. In our empirical trials, no ambiguous writes were observed; all discrepancies were fully accounted for by leftover test artifacts from prior smoke tests. Complete bucket resets were added between trials to guarantee clean baseline states.

### 3.3 Replication Tradeoff Analysis (Baseline Network)

| Metric | Asynchronous Replication (`--sync disable`) | Synchronous Replication (`--sync enable`) |
|---|---|---|
| **Client PUT Latency** | **3.8 ms** (range: 3.1ms - 4.6ms) | **9.0 ms** (range: 7.2ms - 11.5ms) (~2.4x latency) |
| **Write Confirmation** | HTTP 200 returned upon local write to primary | HTTP 200 returned only after replica acknowledged by secondary |
| **Measured Baseline RPO (Normal WAN)** | **0 missing objects** (local bridge network replication lag < 80ms) | **0 missing objects** (guaranteed zero data loss) |
| **RPO Exposure Window** | Vulnerable to loss of writes in-flight during replication queue lag | Zero exposure window for any HTTP 200 acknowledged write |
| **Network Partition Impact** | Primary continues accepting writes; queues for resync | Primary blocks/fails writes while secondary is unreachable |

---

## 4. Lag-Injection Chaos Scenario (Active WAN Partition Followed by Crash)

To rigorously test RPO limits, a lag-injection test was executed across 3 trials of Asynchronous mode and 3 trials of Synchronous mode:
1. `minio-b` was severed from `net-wan` (`docker network disconnect net-wan minio-b`).
2. The client continuously streamed writes to `minio-a` through the global proxy for 3.5 seconds.
3. Region A was crashed abruptly via SIGKILL (`docker kill minio-a`).
4. `minio-b` was reconnected to `net-wan`, and failover completed.
5. The writer was stopped, and `scripts/demo/rpo-check.sh` was executed **before restarting Region A**.

### 4.1 Lag-Injection Results Table

| Replication Mode | Trial # | WAN Lag Duration | Client Ack (HTTP 200) | Present on Region B | Acknowledged Missing (RPO) | Failed Writes (HTTP 502/504) | Write Behavior While B Unreachable |
|---|---|---|---|---|---|---|---|
| **Asynchronous** | Trial 1 | 3.5 s | 21 objects | 7 objects | **14 objects lost** | 2 writes | Succeeds immediately (HTTP 200, ~4ms); queues in lag buffer |
| **Asynchronous** | Trial 2 | 3.5 s | 21 objects | 7 objects | **14 objects lost** | 2 writes | Succeeds immediately (HTTP 200, ~4ms); queues in lag buffer |
| **Asynchronous** | Trial 3 | 3.5 s | 22 objects | 8 objects | **14 objects lost** | 2 writes | Succeeds immediately (HTTP 200, ~4ms); queues in lag buffer |
| **Synchronous**  | Trial 1 | 3.5 s | 0 objects | 1 object | **0 objects lost (RPO = 0)** | 3 writes | Hangs for ~3.8s waiting for B; fails with HTTP 502; zero 200s |
| **Synchronous**  | Trial 2 | 3.5 s | 0 objects | 1 object | **0 objects lost (RPO = 0)** | 3 writes | Hangs for ~3.8s waiting for B; fails with HTTP 502/504; zero 200s |
| **Synchronous**  | Trial 3 | 3.5 s | 0 objects | 1 object | **0 objects lost (RPO = 0)** | 3 writes | Hangs for ~3.8s waiting for B; fails with HTTP 502/504; zero 200s |

### 4.2 Key Findings: CAP Theorem & Consistency vs Availability

1. **Asynchronous Mode (AP):** Maintains 100% write availability during network partitions (~4ms PUT latency). However, if the primary crashes before the partition heals, all writes queued in the replication backlog (`obj-00001.txt` through `obj-00014.txt`) are lost upon failover, producing a measured RPO of 14 objects.
2. **Synchronous Mode (CP):** Strictly enforces consistency and zero data loss (RPO = 0). When Region B is unreachable across the WAN, writes to `minio-a` hang waiting for the remote replica, eventually timing out and returning HTTP 502/504. Because no writes are acknowledged to the client during the partition, zero acknowledged writes are lost when Region A crashes.

### 4.3 Long-Duration Lag-Injection Test (30-Second Partition in Synchronous Mode)

To verify behavior under extended partitions, 3 trials were executed with `minio-b` partitioned from `net-wan` for a full 30 seconds of active client writes prior to crashing `minio-a`:

| Trial # | Partition Duration | Early Writes (0–10s) Status & Latency | Late Writes (10–30s) Status & Latency | Client Acked (HTTP 200) | Present on Region B | Acked but Missing (RPO) |
|---|---|---|---|---|---|---|
| **Trial 1** | 30.0 s | TimeoutError / HTTP 0 (avg: 7939.5 ms) | TimeoutError / HTTP 0 (avg: 5004.9 ms) | **0 objects** | 0 objects | **0 objects lost (RPO = 0)** |
| **Trial 2** | 30.0 s | HTTP 502 Bad Gateway (avg: 4005.8 ms) | HTTP 502 Bad Gateway (avg: 4598.8 ms) | **0 objects** | 0 objects | **0 objects lost (RPO = 0)** |
| **Trial 3** | 30.0 s | HTTP 502 Bad Gateway (avg: 4004.6 ms) | HTTP 502 Bad Gateway (avg: 4590.4 ms) | **0 objects** | 0 objects | **0 objects lost (RPO = 0)** |

**Early vs. Late Write Analysis:**
- **Early Writes (0–10s):** Every request blocks waiting for the replica acknowledgement. Requests terminate at either the client-side timeout (~5.0s to ~7.9s) or Nginx gateway timeout (~4.0s) returning HTTP 502 Bad Gateway. Exactly zero writes succeed.
- **Late Writes (10–30s):** MinIO continues to strictly enforce synchronous replication without falling back to local-only async writes. Requests continue to block and return HTTP 502 Bad Gateway (~4.0s to ~6.9s).
- **RPO Audit Result:** Pre-restart audit (`scripts/demo/rpo-check.sh`) confirmed 0 client-acknowledged writes and 0 objects missing on Region B.

### 4.4 Exact Conditions for Synchronous Zero Data Loss Guarantees

- **When Synchronous Mode Guarantees Zero Data Loss (RPO = 0):**
  Synchronous replication guarantees zero data loss strictly for **client-acknowledged (HTTP 200) writes**. A write will never return HTTP 200 to the client until both the local primary and the secondary replica have confirmed persistent write to disk. If the network or secondary fails, writes fail rather than returning un-replicated success. Therefore, if the primary crashes at any time, all client-acknowledged data is guaranteed to exist on the secondary (RPO = 0).
- **When Synchronous Mode Does NOT Guarantee Zero Loss / Tradeoffs:**
  - **Availability Tradeoff (CP):** Under network partitions or secondary node failure, write availability drops to 0%. Clients receive HTTP 502/504 errors or connection timeouts.
  - **In-Doubt / Ambiguous Writes:** If a primary crashes after the replica was persisted on Region B but before the HTTP 200 response reached the client, the client observes a failed request (HTTP 502) even though the data was saved.
  - **Demotion on Failover:** Because failover removes the surviving node's replication rule to enable unblocked writes, if a false-positive failover occurs, both regions will operate independently and diverge until manual failback resynchronizes them.

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
