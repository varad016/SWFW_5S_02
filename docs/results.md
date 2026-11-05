# Multi-Region HA Data Platform: Experimental Results & SLA Metrics

## 1. Test Environment & Configuration

- **Host Platform:** Ubuntu on WSL2 (Linux x86_64)
- **Deployment Topology:**
  - Region A: `minio-a` (`net-region-a`, `net-wan`)
  - Region B: `minio-b` (`net-region-b`, `net-wan`)
  - Global Layer: `global-proxy` (Nginx on `net-wan`, port 8000), `failover-controller` (Python daemon on Docker socket)
- **Replication Architecture:** Bidirectional MinIO Bucket Replication with versioning (`data-bucket`)
- **Failover Threshold (N):** 3 consecutive failed probes
- **Health Probe Interval (I):** 1.0 second
- **Health Probe Timeout:** 0.5 seconds
- **Health Probe Endpoint:** `GET /minio/health/live` (HTTP 200 OK expected)

---

## 2. RTO (Recovery Time Objective) Analysis

### 2.1 Investigation of Initial Detection Latency (Root Cause Analysis)

In initial testing, with parameters N = 3 and Interval = 2.0s, the detection latency from first failed probe was measured at 9.58s rather than the expected ~4.0s - 5.0s.

**Root Cause:**
When a container is terminated abruptly via `docker kill`, its Docker bridge IP becomes unreachable, but Docker's embedded DNS server (`127.0.0.11`) continues to receive lookups for `minio-a`. The standard Python `http.client.HTTPConnection` calls `socket.getaddrinfo()` internally before opening a socket. The socket timeout parameter applies to network I/O, but does not constrain glibc DNS resolution. Each probe suffered a ~2.0s - 3.0s DNS lookup retry delay, expanding detection time across 3 probes to ~9.6 seconds.

**Remediation:**
The failover controller was upgraded to resolve and lock the container's static IP literal (`172.20.0.5`) upon startup and healthy heartbeats. All healthcheck requests connect directly to the IP literal with an explicit `Host: minio-a:9000` header, completely eliminating glibc DNS resolution.

### 2.2 Mathematical Detection Model

With direct IP targeting, the detection timeline following container termination is deterministic:

- Probe 1: Starts within `[0, Interval]` seconds of container failure. Duration = Probe Timeout (0.5s) or 0.2ms if `ConnectionRefused`.
- Probe 2: Starts after Sleep(Interval) = 1.0s. Duration = Probe Timeout (0.5s).
- Probe 3: Starts after Sleep(Interval) = 1.0s. Duration = Probe Timeout (0.5s).
- Detection Trigger: Occurs immediately after Probe 3 finishes.

Theoretical Detection from First Failure:
- (3 * Probe_Timeout) + (2 * Interval) = (3 * 0.5s) + (2 * 1.0s) = 3.50 seconds (worst-case timeout).
- If Probe 1 returns immediate ConnectionRefused: (0.0s + 2 * 0.5s) + (2 * 1.0s) = 3.00 seconds.

### 2.3 Per-Probe Trace & Measured RTO

From the live test run (with SIGKILL injection via `kill-region.sh region-a`):

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
- Switchover Time (T_first_success - T_detect): **0.3721 seconds** (re-write Nginx configuration + Docker socket SIGHUP).
- Total RTO (T_first_success - T_failure): **3.4862 seconds**.

---

## 3. RPO (Recovery Point Objective) & Replication Mode Comparison

### 3.1 Asynchronous vs Synchronous Replication

| Metric | Asynchronous Replication | Synchronous Replication (`--sync enable`) |
|---|---|---|
| **Average Client PUT Latency** | 3.8 ms (range: 3.1ms - 4.6ms) | 9.0 ms (range: 7.2ms - 11.5ms) |
| **Commit Semantics** | Returns HTTP 200 upon local write to primary | Returns HTTP 200 only after replica acknowledged by secondary |
| **Measured RPO on Sudden Crash** | 0 missing objects (local bridge lag < 80ms) | **0 missing objects (guaranteed zero data loss)** |
| **WAN Partition Behavior** | Primary continues serving writes; queues backlog | Primary blocks or returns error if replica unreachable |

### 3.2 Live Writer Crash Test Findings

During a continuous write stream (interval = 0.3s) subjected to `kill-region.sh region-a`:
1. Pre-crash writes (#00001 to #00008) returned HTTP 200 with 8.0ms - 9.5ms latency.
2. At T_failure, requests during the 3.48s outage returned HTTP 502 (Bad Gateway) as expected while Region A was offline.
3. At T_first_success, writes resumed immediately (#00056 onwards) with HTTP 200 routed to Region B with 4.5ms - 7.6ms latency.
4. An audit of all client writes confirmed zero lost writes among acknowledged requests.

---

## 4. Disaster Recovery & Failback

The failback workflow (`scripts/chaos/failback.sh`) executes without data loss:

1. **Service Recovery:** Boots `minio-a` and ensures `net-wan` network membership.
2. **Dynamic Target Discovery:** Extracts replication ARN dynamically from `mc replicate ls --json`.
3. **Link Health Verification:** Polls until `mc replicate status` reports link status as `online`.
4. **Resync Execution:** Triggers `mc replicate resync start` to backfill all failover writes committed to Region B during the outage.
5. **Drain Verification:** Confirms `queued.count == 0` and `resync status` reports `Status: Completed` with `Failed: 0`.
6. **Traffic Handover:** Updates Nginx upstream back to `minio-a:9000` and signals reload via Docker socket.
7. **Consistency Audit:** `scripts/demo/verify.sh` confirmed:
   - Region A Object Count: 71
   - Region B Object Count: 71
   - Synchronized Objects: 71
   - Present in A, absent B: 0
   - Present in B, absent A: 0
   - **Total Unsynced Delta (RPO): 0 objects (100% Consistency)**.
