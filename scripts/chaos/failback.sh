#!/usr/bin/env bash
# ==============================================================================
# Failback Workflow (Manual by Design)
# Safely restores primary operations to Region A after an outage:
# 1. Ensures Region A container is started and healthy.
# 2. Ensures WAN bridge connectivity is restored.
# 3. Dynamically discovers replication ARNs (no hardcoded values).
# 4. Triggers resync to replicate any writes accepted by Region B back to Region A.
# 5. Waits for replication backlog queues to drain to zero.
# 6. Repoints Global Nginx Proxy back to Region A and reloads configuration.
# 7. Clears chaos gating flag (.chaos-active).
# ==============================================================================

set -eu

BUCKET="${BUCKET_NAME:-data-bucket}"
CHAOS_FLAG=".chaos-active"
PROXY_URL="http://localhost:8000"

echo "=================================================================="
echo "== HA Data Platform - Failback to Region A                      =="
echo "=================================================================="

# 1. Ensure minio-a container is running
echo "1. Ensuring minio-a container is running..."
if ! docker ps --format '{{.Names}}' | grep -q "^minio-a$"; then
  echo "   Starting minio-a..."
  docker start minio-a >/dev/null
fi

# 2. Ensure WAN connectivity for both regions
echo "2. Ensuring WAN network connectivity..."
docker network connect net-wan minio-a 2>/dev/null || true
docker network connect net-wan minio-b 2>/dev/null || true

# Wait for Region A to be healthy
echo "   Waiting for Region A to become healthy..."
attempts=0
until docker exec minio-a mc admin info local >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 30 ]; then
    echo "[ERROR] Timeout waiting for minio-a to become ready."
    exit 1
  fi
  sleep 1
done
echo "   minio-a is online and healthy."

# 3. Dynamically discover replication ARN on Region B
echo "3. Dynamically discovering replication ARN on Region B..."
ARN_B=$(docker exec minio-b mc replicate ls local/"${BUCKET}" 2>/dev/null | awk '/ARN:/ {print $2; exit}' || true)

if [ -z "${ARN_B}" ]; then
  # Fallback to JSON parsing
  ARN_B=$(docker exec minio-b mc replicate ls --json local/"${BUCKET}" 2>/dev/null | grep -o '"Bucket":"arn:minio:replication:[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
fi

if [ -z "${ARN_B}" ]; then
  echo "[ERROR] Could not discover replication ARN on minio-b."
  exit 1
fi
echo "   Discovered ARN (B -> A): ${ARN_B}"

# 4. Trigger replication resync from Region B to Region A
echo "4. Triggering resync from Region B to Region A to backfill failover writes..."
docker exec minio-b mc replicate resync start local/"${BUCKET}" --remote-bucket "${ARN_B}" >/dev/null 2>&1 || true

# 5. Wait for replication queue to drain
echo "5. Monitoring replication queue drain..."
drain_timeout=30
t_start=$(date +%s)
drained=false

while [ $(( $(date +%s) - t_start )) -lt "${drain_timeout}" ]; do
  status_json=$(docker exec minio-b mc replicate status --json local/"${BUCKET}" 2>/dev/null || echo "{}")
  queued_count=$(echo "${status_json}" | grep -o '"queued":{"curr":{"count":[0-9]*' | head -n 1 | awk -F: '{print $NF}' || echo "")

  if [ "${queued_count}" = "0" ]; then
    drained=true
    break
  fi
  sleep 0.5
done

if [ "${drained}" = true ]; then
  echo "   Replication queue drained to 0."
else
  echo "   [WARN] Queue drain check timed out, proceeding with failback."
fi

# 6. Repoint Global Proxy back to minio-a
echo "6. Repointing Global Proxy upstream to minio-a:9000..."
cat << 'EOF' > config/global/nginx.conf
server {
    listen 8000;
    server_name _;

    resolver 127.0.0.11 valid=2s ipv6=off;
    set $backend_upstream http://minio-a:9000;

    client_max_body_size 0;
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        proxy_pass $backend_upstream;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 1s;
        proxy_read_timeout 30s;
        proxy_send_timeout 30s;
    }
}
EOF

docker exec global-proxy nginx -s reload >/dev/null 2>&1

# 7. Reset failover controller to primary state
echo "7. Resetting Failover Controller..."
docker restart failover-controller >/dev/null

# 8. Clear chaos active flag
if [ -f "${CHAOS_FLAG}" ]; then
  rm -f "${CHAOS_FLAG}"
  echo "8. Cleared ${CHAOS_FLAG} flag."
fi

# 9. Verify proxy endpoint
echo "9. Verifying Global Proxy status..."
sleep 1
http_status=$(curl -s -o /dev/null -w "%{http_code}" "${PROXY_URL}/minio/health/live" || echo "000")

echo "=================================================================="
if [ "${http_status}" = "200" ]; then
  echo "[PASS] Failback complete. Global Proxy successfully routing to Region A (HTTP ${http_status})."
else
  echo "[WARN] Failback completed but proxy returned HTTP ${http_status}. Check proxy logs."
fi
echo "=================================================================="
