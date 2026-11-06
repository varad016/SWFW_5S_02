#!/bin/sh
set -eu

echo "============================================================"
echo "== Provisioning Multi-Region MinIO Infrastructure         =="
echo "============================================================"

if [ -z "${MINIO_ROOT_USER:-}" ] || [ -z "${MINIO_ROOT_PASSWORD:-}" ] || \
   [ -z "${REPL_USER:-}" ] || [ -z "${REPL_PASSWORD:-}" ] || [ -z "${BUCKET_NAME:-}" ]; then
  echo "Error: Required environment variables are missing."
  echo "Ensure MINIO_ROOT_USER, MINIO_ROOT_PASSWORD, REPL_USER, REPL_PASSWORD, and BUCKET_NAME are set."
  exit 1
fi

ENDPOINT_A="http://minio-a:9000"
ENDPOINT_B="http://minio-b:9000"

echo "Waiting for Region A (${ENDPOINT_A}) to become healthy..."
attempts=0
until mc alias set minio-a "${ENDPOINT_A}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1 && \
      mc admin info minio-a >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 60 ]; then
    echo "Timeout waiting for Region A (${ENDPOINT_A})."
    exit 1
  fi
  sleep 1
done
echo "Region A is online and ready."

echo "Waiting for Region B (${ENDPOINT_B}) to become healthy..."
attempts=0
until mc alias set minio-b "${ENDPOINT_B}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1 && \
      mc admin info minio-b >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 60 ]; then
    echo "Timeout waiting for Region B (${ENDPOINT_B})."
    exit 1
  fi
  sleep 1
done
echo "Region B is online and ready."

echo "Configuring dedicated replication service user on both regions..."
mc admin user add minio-a "${REPL_USER}" "${REPL_PASSWORD}" 2>/dev/null || true
mc admin user add minio-b "${REPL_USER}" "${REPL_PASSWORD}" 2>/dev/null || true
mc admin policy attach minio-a readwrite --user "${REPL_USER}" 2>/dev/null || true
mc admin policy attach minio-b readwrite --user "${REPL_USER}" 2>/dev/null || true

echo "Configuring buckets and enabling bucket versioning..."
mc mb --ignore-existing minio-a/"${BUCKET_NAME}" 2>/dev/null || true
mc mb --ignore-existing minio-b/"${BUCKET_NAME}" 2>/dev/null || true
mc version enable minio-a/"${BUCKET_NAME}" 2>/dev/null || true
mc version enable minio-b/"${BUCKET_NAME}" 2>/dev/null || true
mc anonymous set public minio-a/"${BUCKET_NAME}" 2>/dev/null || true
mc anonymous set public minio-b/"${BUCKET_NAME}" 2>/dev/null || true

echo "Configuring cross-region bucket replication rules..."
rules_a=$(mc replicate ls minio-a/"${BUCKET_NAME}" 2>/dev/null || true)
case "$rules_a" in
  *"minio-b:9000/${BUCKET_NAME}"*)
    echo "Replication rule minio-a -> minio-b already present."
    ;;
  *)
    echo "Applying replication rule: minio-a -> minio-b"
    mc replicate add minio-a/"${BUCKET_NAME}" \
      --remote-bucket "http://${REPL_USER}:${REPL_PASSWORD}@minio-b:9000/${BUCKET_NAME}" \
      --priority 1
    ;;
esac

rules_b=$(mc replicate ls minio-b/"${BUCKET_NAME}" 2>/dev/null || true)
case "$rules_b" in
  *"minio-a:9000/${BUCKET_NAME}"*)
    echo "Replication rule minio-b -> minio-a already present."
    ;;
  *)
    echo "Applying replication rule: minio-b -> minio-a"
    mc replicate add minio-b/"${BUCKET_NAME}" \
      --remote-bucket "http://${REPL_USER}:${REPL_PASSWORD}@minio-a:9000/${BUCKET_NAME}" \
      --priority 1
    ;;
esac

echo "============================================================"
echo "== Replication Setup Complete. Checking Status:           =="
echo "============================================================"
echo "-- Region A Replication Status --"
mc replicate status minio-a/"${BUCKET_NAME}" || true
echo "-- Region B Replication Status --"
mc replicate status minio-b/"${BUCKET_NAME}" || true
echo "Provisioning succeeded."
