#!/usr/bin/env bash
# ==============================================================================
# Chaos: Heal WAN (Network Restoration)
# Reconnects a container to the inter-region WAN bridge (net-wan) and clears chaos flag.
# ==============================================================================

set -eu

TARGET="${1:-minio-b}"
NETWORK="net-wan"
CHAOS_FLAG=".chaos-active"

echo "=================================================================="
echo "== Chaos Resolution: Healing WAN Partition                      =="
echo "   Target  : ${TARGET}"
echo "   Network : ${NETWORK}"
echo "=================================================================="

echo "1. Reconnecting ${TARGET} to ${NETWORK}..."
docker network connect "${NETWORK}" "${TARGET}" 2>/dev/null || {
  echo "[WARN] ${TARGET} already connected to ${NETWORK}."
}

if [ -f "${CHAOS_FLAG}" ]; then
  rm -f "${CHAOS_FLAG}"
  echo "2. Cleared ${CHAOS_FLAG} flag."
fi

echo "=================================================================="
echo "[SUCCESS] WAN connection restored for ${TARGET}."
echo "=================================================================="
