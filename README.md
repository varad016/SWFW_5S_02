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
2. **Replication Strategy:** Bidirectional active-active bucket replication using dedicated service accounts (`mc replicate add`) over `net-wan`.
3. **Global Proxy & Failover:** Edge reverse proxy routing traffic to the active region with automatic failover tracking RTO (Recovery Time Objective).
4. **GitOps Reconciler:** Background reconciler running on the host watching `origin/main` for drift management.

---

## Known Shortcuts & Architecture Notes

> [!NOTE]
> **Container User Permissions (`user: "0:0"`):**
> MinIO containers in `docker-compose.yml` run as `user: "0:0"` (root). By default, Chainguard MinIO images run under non-root UID `65532`. Because host volume mounts on WSL2 can default to differing UID/GIDs, running as root is used as an intentional development shortcut to prevent host bind-mount permission conflicts across Linux/WSL environments. In a production deployment, directory permissions should instead be pre-chowned to UID `65532` with non-root security contexts enforced.

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
| **Region A S3 API** | `http://localhost:9001` | Direct API endpoint for Region A |
| **Region A Console** | `http://localhost:9002` | MinIO Web UI Console for Region A |
| **Region B S3 API** | `http://localhost:9011` | Direct API endpoint for Region B |
| **Region B Console** | `http://localhost:9012` | MinIO Web UI Console for Region B |
| **Global Entrypoint** | `http://localhost:8000` | High-availability active proxy (Nginx) |
