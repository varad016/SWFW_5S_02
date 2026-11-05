#!/usr/bin/env bash
# ==============================================================================
# Chaos: Kill Region (Crash Simulation)
# Immediately terminates all containers in target region using SIGKILL (docker kill).
# Records failure timestamp for RTO measurements and creates .chaos-active flag.
# ==============================================================================

set -eu

REGION="${1:-region-a}"
METRICS_DIR="volumes/metrics"
TIMESTAMP_FILE="${METRICS_DIR}/failure.timestamp"
CHAOS_FLAG=".chaos-active"

mkdir -p "${METRICS_DIR}"

if [ "${REGION}" = "region-a" ]; then
  TARGET_CONTAINER="minio-a"
elif [ "${REGION}" = "region-b" ]; then
  TARGET_CONTAINER="minio-b"
else
  echo "[ERROR] Unknown region: ${REGION}. Specify region-a or region-b."
  exit 1
fi

echo "=================================================================="
echo "== Chaos Injection: Hard Crash Simulation (${REGION})           =="
echo "   Target Container : ${TARGET_CONTAINER}"
echo "   Action           : docker kill (SIGKILL)"
echo "=================================================================="

# 1. Record precise failure timestamp before kill
t_failure=$(date +%s.%N)
echo "${t_failure}" > "${TIMESTAMP_FILE}"
echo "1. Recorded crash timestamp T_failure = ${t_failure} in ${TIMESTAMP_FILE}"

# 2. Set chaos active gating flag so GitOps reconciler does not interfere
touch "${CHAOS_FLAG}"
echo "2. Created ${CHAOS_FLAG} gating flag."

# 3. Crash target container immediately with SIGKILL
echo "3. Issuing docker kill ${TARGET_CONTAINER}..."
docker kill "${TARGET_CONTAINER}" >/dev/null 2>&1 || true

echo "=================================================================="
echo "[CHAOS ACTIVE] ${REGION} (${TARGET_CONTAINER}) has crashed."
echo "Failover controller is monitoring and will failover after N failures."
echo "=================================================================="
