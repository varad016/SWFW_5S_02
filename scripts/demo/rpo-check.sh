#!/usr/bin/env bash
# ==============================================================================
# Demo RPO Checker (Before-Restart Audit)
# Compares HTTP 200 acknowledged writes in writer.log against objects present
# on the surviving Region B while Region A is down (before restart/failback).
# Any acknowledged write missing on Region B represents true RPO data loss.
# ==============================================================================

set -eu

BUCKET="${BUCKET_NAME:-data-bucket}"
LOG_FILE="${1:-volumes/metrics/writer.log}"
TMP_DIR="/tmp/minio_rpo_$$"
mkdir -p "${TMP_DIR}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=================================================================="
echo "== HA Data Platform - Pre-Restart RPO Audit                     =="
echo "   Bucket      : ${BUCKET}"
echo "   Writer Log  : ${LOG_FILE}"
echo "=================================================================="

if [ ! -f "${LOG_FILE}" ]; then
  echo "[ERROR] Log file ${LOG_FILE} not found."
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^minio-b$"; then
  echo "[ERROR] minio-b container is not running."
  exit 1
fi

# 1. Extract all objects that returned HTTP 200 from writer.log
awk -F, '$4 == "200" {print "obj-" $3 ".txt"}' "${LOG_FILE}" | sort -u > "${TMP_DIR}/acknowledged_200.txt"
ack_count=$(wc -l < "${TMP_DIR}/acknowledged_200.txt")
echo "1. Extracted HTTP 200 acknowledged writes from client log: ${ack_count} objects"

# 2. Query object inventory on surviving Region B (while minio-a is down)
docker exec minio-b mc ls "local/${BUCKET}" 2>/dev/null | awk '{print $NF}' | sort > "${TMP_DIR}/objects_region_b.txt"
b_count=$(wc -l < "${TMP_DIR}/objects_region_b.txt")
echo "2. Inventory on surviving Region B: ${b_count} objects"

# 3. Find acknowledged writes missing on Region B
comm -23 "${TMP_DIR}/acknowledged_200.txt" "${TMP_DIR}/objects_region_b.txt" > "${TMP_DIR}/missing_on_b.txt"
missing_count=$(wc -l < "${TMP_DIR}/missing_on_b.txt")

echo ""
echo "=================================================================="
echo "== Pre-Restart RPO Audit Results                                =="
echo "=================================================================="
echo "   Client Acknowledged (HTTP 200) : ${ack_count} objects"
echo "   Surviving on Region B          : ${b_count} objects"
echo "   Acknowledged but Missing (RPO) : ${missing_count} objects"
echo "=================================================================="

if [ "${missing_count}" -eq 0 ]; then
  echo "[PASS] Zero Data Loss. RPO = 0 (All acknowledged writes survived on Region B)."
  exit 0
else
  echo "[WARN] Real RPO Data Loss Detected: ${missing_count} acknowledged writes lost!"
  echo "--- Missing Object Keys on Region B: ---"
  head -n 20 "${TMP_DIR}/missing_on_b.txt"
  exit 2
fi
