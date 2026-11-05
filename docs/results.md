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

---

## 3. Real RPO & Replication Mode Comparison

### 3.1 Pre-Restart RPO Methodology (`scripts/demo/rpo-check.sh`)

To measure true RPO without masking data loss via post-recovery replication:
1. Client writer streams numbered objects through the global proxy (`http://localhost:8000`).
2. Region A is terminated abruptly via SIGKILL (`kill-region.sh region-a`).
3. The failover controller switches traffic to Region B.
4. The writer is stopped.
5. **Before restarting Region A**, `scripts/demo/rpo-check.sh` compares the list of objects that returned HTTP 200 in `writer.log` against the objects actually present on surviving Region B. Any acknowledged write missing on Region B represents true RPO data loss.

### 3.2 10-Trial Experimental Results (5 Async vs 5 Sync)

The test suite executed 10 independent trials with varied kill timing offsets:

| Replication Mode | Trial # | Pre-Kill Delay | Client Ack (HTTP 200) | Present on Region B | Acknowledged Missing (RPO) | Failed Writes (HTTP 502) | Client-Visible Outage Gap |
|---|---|---|---|---|---|---|---|
| **Asynchronous** | Trial 1 | 1.0 s | 21 objects | 24 objects | **0 objects** | 3 writes | 4.68 s |
| **Asynchronous** | Trial 2 | 1.8 s | 23 objects | 26 objects | **0 objects** | 3 writes | 4.76 s |
| **Asynchronous** | Trial 3 | 2.5 s | 29 objects | 32 objects | **0 objects** | 4 writes | 4.88 s |
| **Asynchronous** | Trial 4 | 3.2 s | 34 objects | 37 objects | **0 objects** | 3 writes | 4.70 s |
| **Asynchronous** | Trial 5 | 0.7 s | 20 objects | 23 objects | **0 objects** | 3 writes | 4.69 s |
| **Synchronous**  | Trial 1 | 1.0 s | 6 objects | 10 objects | **0 objects** | 3 writes | 4.71 s |
| **Synchronous**  | Trial 2 | 1.8 s | 11 objects | 15 objects | **0 objects** | 3 writes | 4.75 s |
| **Synchronous**  | Trial 3 | 2.5 s | 14 objects | 18 objects | **0 objects** | 4 writes | 4.82 s |
| **Synchronous**  | Trial 4 | 3.2 s | 18 objects | 22 objects | **0 objects** | 3 writes | 4.73 s |
| **Synchronous**  | Trial 5 | 0.7 s | 18 objects | 22 objects | **0 objects** | 4 writes | 4.88 s |

### 3.3 Replication Tradeoff Analysis

| Metric | Asynchronous Replication (`--sync disable`) | Synchronous Replication (`--sync enable`) |
|---|---|---|
| **Client PUT Latency** | **3.8 ms** (range: 3.1ms - 4.6ms) | **9.0 ms** (range: 7.2ms - 11.5ms) (~2.4x latency) |
| **Write Confirmation** | HTTP 200 returned upon local write to primary | HTTP 200 returned only after replica acknowledged by secondary |
| **Measured RPO on Sudden Crash** | **0 missing objects** across 5 trials (local network replication lag < 80ms) | **0 missing objects** (mathematically guaranteed zero data loss) |
| **RPO Exposure Window** | Vulnerable to loss of writes in-flight during replication lag window | Zero exposure window for any HTTP 200 acknowledged write |
| **Network Partition Impact** | Primary continues accepting writes; queues for resync | Primary fails writes if secondary is unreachable |

---

## 4. Disaster Recovery & Failback Eventual Consistency

Failback is intentionally manual (`scripts/chaos/failback.sh`) to prevent flapping and split-brain:

1. **Service Recovery:** Starts `minio-a` and reconnects `net-wan`.
2. **Replication Link Health:** Waits until `mc replicate status` reports link status as `online`.
3. **Resync Execution:** Triggers `mc replicate resync start` to backfill all failover writes committed to Region B during the outage.
4. **Drain Verification:** Confirms `queued.count == 0` and `resync status` reports `Status: Completed` with `Failed: 0`.
5. **Traffic Handover:** Updates Nginx upstream back to `minio-a:9000` and reloads via Docker socket.
6. **Eventual Consistency Audit:** `scripts/demo/verify.sh` confirmed:
   - Region A Total Objects: 71
   - Region B Total Objects: 71
   - Synchronized Objects: 71
   - Out-of-Sync Discrepancy: 0 objects (**100% Eventual Consistency Achieved**).
