#!/usr/bin/env bash
# ==============================================================================
# Chaos: Partition WAN (Network Severing Simulation)
# Disconnects a target container or region from the inter-region WAN bridge (net-wan).
# Local regional traffic remains intact while cross-region traffic drops.
# ==============================================================================

set -eu

TARGET="${1:-minio-b}"
NETWORK="net-wan"
CHAOS_FLAG=".chaos-active"

echo "=================================================================="
echo "== Chaos Injection: WAN Partition Simulation                    =="
echo "   Target  : ${TARGET}"
echo "   Network : ${NETWORK}"
echo "=================================================================="

touch "${CHAOS_FLAG}"
echo "1. Created ${CHAOS_FLAG} gating flag."

echo "2. Disconnecting ${TARGET} from ${NETWORK}..."
docker network disconnect "${NETWORK}" "${TARGET}" 2>/dev/null || {
  echo "[WARN] ${TARGET} was not attached to ${NETWORK} or already disconnected."
}

echo "=================================================================="
echo "[CHAOS ACTIVE] WAN link partitioned for ${TARGET}."
echo "Local network is operational; cross-region replication is severed."
echo "=================================================================="
