#!/usr/bin/env bash
# ==============================================================================
# Chaos: Stop Container (Process Failure Simulation)
# Stops an individual service container and activates the .chaos-active flag.
# ==============================================================================

set -eu

CONTAINER="${1:-}"
CHAOS_FLAG=".chaos-active"

if [ -z "${CONTAINER}" ]; then
  echo "Usage: $0 <container-name>"
  echo "Example: $0 minio-a"
  exit 1
fi

echo "=================================================================="
echo "== Chaos Injection: Stopping Container (${CONTAINER})           =="
echo "=================================================================="

touch "${CHAOS_FLAG}"
echo "1. Created ${CHAOS_FLAG} gating flag."

echo "2. Stopping ${CONTAINER}..."
docker stop "${CONTAINER}"

echo "[CHAOS ACTIVE] ${CONTAINER} stopped."
