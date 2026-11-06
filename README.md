# Multi-Region HA Data Platform Simulation

Local multi-region High Availability (HA) data platform simulation on a single Linux machine (WSL2 Ubuntu) using Docker Compose.

The platform simulates two independent fault domains (`region-a` and `region-b`), each on its own isolated Docker network, with cross-region replication passing across a simulated inter-region WAN network (`net-wan`).

---

## Architecture Overview

```
                      Client Requests
                             │
                             ▼
                [ Global Ingress Proxy ]
                   (Nginx / Port 8000)
                             │
               ┌─────────────┴─────────────┐
               │    net-wan (Backbone)     │
               └─────────────┬─────────────┘
                             │
        ┌────────────────────┴────────────────────┐
        ▼                                         ▼
   [ Region A ]                              [ Region B ]
net-region-a (172.28.10.0/24)             net-region-b (172.28.20.0/24)
├── minio-a                               ├── minio-b
│   (joined to net-wan)                       (joined to net-wan)
└── volumes/region-a/minio-data           └── volumes/region-b/minio-data
```

### Components
1. **Region A & B MinIO Storage:** Single-node S3-compatible instances with versioned buckets.
2. **Replication Strategy:** Bidirectional active-active bucket replication using dedicated service accounts (`mc replicate add`) over `net-wan`. By default, replication operates in **asynchronous mode** for low write latency (~3.8ms), with synchronous mode (`--sync enable`) available as a zero-RPO configuration option.
3. **Global Proxy & Failover:** Edge reverse proxy routing traffic to the active region with automatic failover tracking Recovery Time Objective (RTO).
4. **GitOps Reconciler:** Background reconciler running on the host watching `origin/main` for drift management.

---

## Known Shortcuts & Architecture Notes

> [!NOTE]
> **Container User Permissions (`user: "0:0"`):**
> MinIO containers in `docker-compose.yml` run as `user: "0:0"` (root). By default, Chainguard MinIO images run under non-root UID 65532. Because host volume mounts on WSL2 can default to differing UID/GIDs, running as root is used as an intentional development shortcut to prevent host bind-mount permission conflicts across Linux/WSL environments. In a production deployment, directory permissions should instead be pre-chowned to UID 65532 with non-root security contexts enforced.

> [!NOTE]
> **Docker Socket Access (`/var/run/docker.sock`):**
> The failover controller container mounts `/var/run/docker.sock` to issue SIGHUP reload signals directly to the Nginx proxy container over the Docker Engine API. This avoids running heavy Docker CLI binaries or SSH daemons inside the controller.

> [!IMPORTANT]
> **Manual Failback by Design:**
> While failover from Region A to Region B is completely automated upon detecting consecutive healthcheck probe failures, **failback to Region A is intentionally manual**. This prevents cluster flapping, split-brain scenarios, and accidental traffic restoration before cross-region replication queues have completely caught up. Failback is executed safely via `scripts/chaos/failback.sh`.

> [!WARNING]
> **Failover Demotion & False-Positive Divergence Risk:**
> Upon initiating automated failover, the failover controller removes Region B's replication rule (`mc replicate rm local/data-bucket --all --force`) via the Docker socket. This demotes Region B to standalone mode so client writes never hang or block even if synchronous replication was active. Consequently, if a **false-positive failover** occurs (e.g. transient probe packet loss while Region A was actually still running and accepting client writes), both regions will accept independent writes and **diverge** until an operator intervenes and executes `scripts/chaos/failback.sh` to trigger bidirectional resync and merge object histories.

> [!NOTE]
> **Synchronous vs. Asynchronous Replication Guarantees:**
> - **Synchronous Mode (`--sync enable`):** Guarantees zero data loss (RPO = 0) for all client-acknowledged writes. Writes to the primary block until the secondary replica acknowledges receipt; if the secondary or WAN link fails, writes fail (HTTP 502 / timeout) rather than returning un-replicated HTTP 200s. **Zero loss is guaranteed strictly for client-acknowledged (HTTP 200) writes.** Under network partitions, write availability drops to 0% (CP mode in CAP theorem).
> - **Asynchronous Mode (`--sync disable`):** Prioritizes write availability (AP mode) with ~4ms PUT latency. If the primary crashes while replication lag exists, writes remaining in the replication backlog buffer prior to the crash are lost upon failover (measured RPO of 14 objects under lag-injection).

---

## Getting Started

### 1. Environment Configuration
Copy the reference template and define local credentials:
```bash
cp .env.example .env
```
Ensure `.env` contains non-default passwords. `.env` is strictly excluded from version control via `.gitignore`.

### 2. Launch the Platform
```bash
docker compose --profile all up -d
```

### 3. Verify Replication Status
```bash
docker exec minio-a mc replicate status local/data-bucket
```

---

## Endpoints

| Service | Host Port | Purpose |
| :--- | :--- | :--- |
| **Global Entrypoint** | `http://localhost:8000` | High-availability active proxy (Nginx) |
| **Region A S3 API** | `http://localhost:9001` | Direct API endpoint for Region A |
| **Region A Console** | `http://localhost:9002` | MinIO Web UI Console for Region A |
| **Region B S3 API** | `http://localhost:9011` | Direct API endpoint for Region B |
| **Region B Console** | `http://localhost:9012` | MinIO Web UI Console for Region B |

---

## Demo Suite

- **Continuous Live Writer Stream:**
  ```bash
  # Streams numbered objects to http://localhost:8000/data-bucket/ (default: 1.0s interval; override via WRITER_INTERVAL)
  ./scripts/demo/writer.sh
  ```
  Logs timestamps, object keys, HTTP codes, and latencies to `volumes/metrics/writer.log`.

- **Pre-Restart RPO Check:**
  ```bash
  # Audits client-acknowledged HTTP 200 writes against surviving Region B before restart
  ./scripts/demo/rpo-check.sh
  ```

- **Cross-Region Eventual Consistency Audit:**
  ```bash
  # Audits object inventories across both regions after failback and reports divergence delta
  ./scripts/demo/verify.sh
  ```

---

## Chaos Engineering Runbook

- **Hard Crash Simulation (Kill Region):**
  ```bash
  ./scripts/chaos/kill-region.sh region-a
  ```
- **Stop Specific Service:**
  ```bash
  ./scripts/chaos/stop-container.sh minio-a
  ```
- **Sever Inter-Region WAN:**
  ```bash
  ./scripts/chaos/partition-wan.sh minio-b
  ```
- **Heal Inter-Region WAN:**
  ```bash
  ./scripts/chaos/heal-wan.sh minio-b
  ```
- **Safe Failback to Region A:**
  ```bash
  ./scripts/chaos/failback.sh
  ```

---

## GitOps Continuous Deployment & Reconciliation

The platform includes a host-based GitOps reconciler (`scripts/gitops/reconciler.sh`) that continuously enforces declared Git state against the active deployment:

- **Isolated Deploy Clone:** The production/demo stack runs strictly from a separate clone (e.g. `~/deploy/SWFW_5S_02`), completely isolated from developer working directories.
- **Chaos Gating:** Reconciler checks `/tmp/.chaos-active` and skips all reconciliation actions during active chaos experiments.
- **Drift Detection & Reversal:** Any manual configuration edits inside the deploy clone are automatically reverted (`git checkout -- .` and `git clean`).
- **Automated Deployment:** Pulls new commits from `origin/main` and runs `docker compose up -d` only upon detected drift or new commits.
- **Generated Upstream Config:** The live Nginx proxy upstream file (`config/global/nginx.conf`) is generated at runtime from `nginx.conf.template` and excluded from git tracking.

```bash
# Run continuous reconciliation loop from deploy clone:
./scripts/gitops/reconciler.sh

# Run one-shot reconciliation check:
./scripts/gitops/reconciler.sh --once
```
