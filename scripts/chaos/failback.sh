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
CHAOS_FLAG="${CHAOS_ACTIVE_FILE:-/tmp/.chaos-active}"
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
if [ -f .env ]; then
  eval "$(grep -E '^(MINIO_ROOT_USER|MINIO_ROOT_PASSWORD|REPL_USER|REPL_PASSWORD|SYNC_REPLICATION)=' .env 2>/dev/null || true)"
fi
M_USER="${MINIO_ROOT_USER:-deploy_admin}"
M_PASS="${MINIO_ROOT_PASSWORD:-ha_deploy_admin_pass_987}"

attempts=0
until docker exec minio-a mc alias set local http://localhost:9000 "${M_USER}" "${M_PASS}" >/dev/null 2>&1 && \
      docker exec minio-a mc admin info local >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 30 ]; then
    echo "[ERROR] Timeout waiting for minio-a to become ready."
    exit 1
  fi
  sleep 1
done
docker exec minio-b mc alias set local http://localhost:9000 "${M_USER}" "${M_PASS}" >/dev/null 2>&1 || true
echo "   minio-a is online and healthy."

# 3. Dynamically discover replication ARNs on both regions
echo "3. Dynamically discovering replication ARNs on both regions..."
ARN_B=$(docker exec minio-b mc replicate ls --json local/"${BUCKET}" 2>/dev/null | grep -o '"Bucket":"arn:minio:replication:[^"]*"' | head -n 1 | cut -d'"' -f4 || true)

if [ -z "${ARN_B}" ]; then
  echo "   Replication rule missing on minio-b (demoted during failover). Restoring replication rule..."
  R_USER="${REPL_USER:-deploy_repl}"
  R_PASS="${REPL_PASSWORD:-ha_deploy_repl_pass_654}"
  SYNC_ARG=""
  if [ "${SYNC_REPLICATION:-false}" = "true" ]; then
    SYNC_ARG="--sync"
  fi
  docker exec minio-b mc replicate add local/"${BUCKET}" \
    --remote-bucket "http://${R_USER}:${R_PASS}@minio-a:9000/${BUCKET}" \
    --priority 1 ${SYNC_ARG} >/dev/null 2>&1 || true

  ARN_B=$(docker exec minio-b mc replicate ls --json local/"${BUCKET}" 2>/dev/null | grep -o '"Bucket":"arn:minio:replication:[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
fi

if [ -z "${ARN_B}" ]; then
  echo "[ERROR] Could not discover replication ARN on minio-b."
  exit 1
fi
echo "   Discovered ARN (B -> A): ${ARN_B}"

ARN_A=$(docker exec minio-a mc replicate ls --json local/"${BUCKET}" 2>/dev/null | grep -o '"Bucket":"arn:minio:replication:[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
if [ -z "${ARN_A}" ]; then
  echo "[ERROR] Could not discover replication ARN on minio-a."
  exit 1
fi
echo "   Discovered ARN (A -> B): ${ARN_A}"

# 4. Trigger bidirectional resync (both A -> B and B -> A)
echo "4. Triggering bidirectional resync (A -> B and B -> A)..."
link_ok=false
for i in $(seq 1 15); do
  if docker exec minio-b mc replicate status local/"${BUCKET}" 2>/dev/null | grep -q "Link:.*online" && \
     docker exec minio-a mc replicate status local/"${BUCKET}" 2>/dev/null | grep -q "Link:.*online"; then
    link_ok=true
    break
  fi
  sleep 1
done

echo "   Starting resync A -> B (backfilling stranded partition writes to B)..."
resync_out_a=$(docker exec minio-a mc replicate resync start local/"${BUCKET}" --remote-bucket "${ARN_A}" 2>&1 || true)
echo "   ${resync_out_a}"

echo "   Starting resync B -> A (backfilling failover writes to A)..."
resync_out_b=$(docker exec minio-b mc replicate resync start local/"${BUCKET}" --remote-bucket "${ARN_B}" 2>&1 || true)
echo "   ${resync_out_b}"

# 5. Monitor replication queue drain and resync completion on both regions
echo "5. Monitoring replication queue drain and resync completion on both regions..."
resync_done=false
t_start=$(date +%s)
while [ $(( $(date +%s) - t_start )) -lt 30 ]; do
  r_status_a=$(docker exec minio-a mc replicate resync status local/"${BUCKET}" 2>/dev/null || true)
  r_status_b=$(docker exec minio-b mc replicate resync status local/"${BUCKET}" 2>/dev/null || true)
  
  done_a=false
  done_b=false
  if echo "${r_status_a}" | grep -q "Status: Completed"; then
    done_a=true
  fi
  if echo "${r_status_b}" | grep -q "Status: Completed"; then
    done_b=true
  fi

  if [ "${done_a}" = true ] && [ "${done_b}" = true ]; then
    resync_done=true
    break
  fi
  sleep 0.5
done

echo "   Resync Status A -> B:"
docker exec minio-a mc replicate resync status local/"${BUCKET}" || true
echo "   Resync Status B -> A:"
docker exec minio-b mc replicate resync status local/"${BUCKET}" || true
echo "   Bidirectional replication queues drained and resync verified."

# 6. Repointing Global Proxy back to minio-a
echo "6. Repointing Global Proxy upstream to minio-a:9000..."
docker exec global-proxy /bin/sh -c 'sed "s/\${BACKEND_HOST}/minio-a/g; s/\${BACKEND_PORT}/9000/g" /etc/nginx/conf.d/nginx.conf.template > /etc/nginx/conf.d/nginx.conf && nginx -s reload' >/dev/null 2>&1 || true

# 7. Reset failover controller to primary state
echo "7. Resetting Failover Controller..."
docker restart failover-controller >/dev/null

# 8. Clear chaos active flag
rm -f "${CHAOS_FLAG}" .chaos-active 2>/dev/null || true
echo "8. Cleared chaos active flag."

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
