#!/usr/bin/env bash
# ==============================================================================
# Demo Object Verifier (Eventual Consistency Audit)
# Compares all objects in data-bucket between Region A and Region B after failback.
# Reports total objects, synchronized count, and out-of-sync delta.
# ==============================================================================

set -eu

BUCKET="${BUCKET_NAME:-data-bucket}"
TMP_DIR="/tmp/minio_verify_$$"
mkdir -p "${TMP_DIR}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "=================================================================="
echo "== HA Data Platform - Cross-Region Eventual Consistency Audit  =="
echo "   Bucket : ${BUCKET}"
echo "=================================================================="

# Check container status
if ! docker ps --format '{{.Names}}' | grep -q "^minio-a$"; then
  echo "[ERROR] minio-a container is not running."
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^minio-b$"; then
  echo "[ERROR] minio-b container is not running."
  exit 1
fi

echo "1. Querying object inventory from Region A..."
docker exec minio-a mc ls "local/${BUCKET}" 2>/dev/null | awk '{print $NF}' | sort > "${TMP_DIR}/objects_a.txt"
count_a=$(wc -l < "${TMP_DIR}/objects_a.txt")
echo "   Region A Object Count: ${count_a}"

echo "2. Querying object inventory from Region B..."
docker exec minio-b mc ls "local/${BUCKET}" 2>/dev/null | awk '{print $NF}' | sort > "${TMP_DIR}/objects_b.txt"
count_b=$(wc -l < "${TMP_DIR}/objects_b.txt")
echo "   Region B Object Count: ${count_b}"

echo "3. Analyzing cross-region synchronization delta..."
comm -12 "${TMP_DIR}/objects_a.txt" "${TMP_DIR}/objects_b.txt" > "${TMP_DIR}/synchronized.txt"
comm -23 "${TMP_DIR}/objects_a.txt" "${TMP_DIR}/objects_b.txt" > "${TMP_DIR}/missing_in_b.txt"
comm -13 "${TMP_DIR}/objects_a.txt" "${TMP_DIR}/objects_b.txt" > "${TMP_DIR}/missing_in_a.txt"

sync_count=$(wc -l < "${TMP_DIR}/synchronized.txt")
missing_b_count=$(wc -l < "${TMP_DIR}/missing_in_b.txt")
missing_a_count=$(wc -l < "${TMP_DIR}/missing_in_a.txt")
total_rpo_delta=$((missing_b_count + missing_a_count))

echo ""
echo "=================================================================="
echo "== Eventual Consistency Audit Results                           =="
echo "=================================================================="
echo "   Region A Total Objects   : ${count_a}"
echo "   Region B Total Objects   : ${count_b}"
echo "   Synchronized Objects     : ${sync_count}"
echo "   Present in A, absent B   : ${missing_b_count}"
echo "   Present in B, absent A   : ${missing_a_count}"
echo "   Out-of-Sync Discrepancy  : ${total_rpo_delta} objects"
echo "=================================================================="

if [ "${total_rpo_delta}" -eq 0 ]; then
  echo "[PASS] 100% Eventual Consistency Achieved (Zero Cross-Region Divergence)."
  exit 0
else
  echo "[WARN] Data discrepancy detected between regions (${total_rpo_delta} out-of-sync objects)."
  if [ "${missing_b_count}" -gt 0 ]; then
    echo "--- Missing in Region B (top 10): ---"
    head -n 10 "${TMP_DIR}/missing_in_b.txt"
  fi
  if [ "${missing_a_count}" -gt 0 ]; then
    echo "--- Missing in Region A (top 10): ---"
    head -n 10 "${TMP_DIR}/missing_in_a.txt"
  fi
  exit 2
fi
