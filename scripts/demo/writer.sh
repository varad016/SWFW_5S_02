#!/usr/bin/env bash
# ==============================================================================
# Demo Object Writer
# Continuously uploads numbered objects to the data platform through the Global Proxy.
# Logs timestamp, object number, and HTTP status code per attempt to track client-visible outages.
# ==============================================================================

set -u

PROXY_URL="${1:-http://localhost:8000}"
BUCKET="${BUCKET_NAME:-data-bucket}"
METRICS_DIR="volumes/metrics"
LOG_FILE="${METRICS_DIR}/writer.log"
INTERVAL="${WRITER_INTERVAL:-1.0}"
MAX_OBJECTS="${MAX_OBJECTS:-0}" # 0 = infinite

mkdir -p "${METRICS_DIR}"

count=0
success=0
failed=0
start_time=$(date +%s)

echo "=================================================================="
echo "== HA Data Platform - Live Object Writer Stream                 =="
echo "   Target Proxy   : ${PROXY_URL}/${BUCKET}/"
echo "   Write Interval : ${INTERVAL}s"
echo "   Log File       : ${LOG_FILE}"
echo "   Press Ctrl+C to stop"
echo "=================================================================="

# Header for log file if new
if [ ! -f "${LOG_FILE}" ]; then
  echo "timestamp_iso,epoch_seconds,object_number,http_status,latency_ms,result" > "${LOG_FILE}"
fi

cleanup() {
  end_time=$(date +%s)
  total_duration=$((end_time - start_time))
  echo ""
  echo "=================================================================="
  echo "== Writer Stream Terminated                                     =="
  echo "   Total Attempts : ${count}"
  echo "   Successful     : ${success}"
  echo "   Failed/Lost    : ${failed}"
  echo "   Total Runtime  : ${total_duration}s"
  if [ "${count}" -gt 0 ]; then
    loss_pct=$(awk "BEGIN {printf \"%.2f\", (${failed}/${count})*100}")
    echo "   Loss Rate      : ${loss_pct}%"
  fi
  echo "=================================================================="
  exit 0
}

trap cleanup SIGINT SIGTERM

while true; do
  count=$((count + 1))
  pad_num=$(printf "%05d" "${count}")
  obj_key="obj-${pad_num}.txt"
  timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  epoch_sec=$(date +%s.%N)
  payload="HA Platform Object ${pad_num} written at ${timestamp_iso} via ${PROXY_URL}"

  # Perform PUT request measuring HTTP status code and response time
  resp=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
    --connect-timeout 2 \
    --max-time 5 \
    -X PUT \
    --data-binary "${payload}" \
    "${PROXY_URL}/${BUCKET}/${obj_key}" 2>/dev/null || echo "000 0.000")

  http_code=$(echo "${resp}" | awk '{print $1}')
  total_time=$(echo "${resp}" | awk '{print $2}')
  latency_ms=$(awk "BEGIN {printf \"%.1f\", ${total_time} * 1000}")

  if [ "${http_code}" = "200" ]; then
    success=$((success + 1))
    result="SUCCESS"
    echo "[${timestamp_iso}] #${pad_num} -> HTTP ${http_code} (${latency_ms}ms) [SUCCESS]"
  else
    failed=$((failed + 1))
    result="FAILED"
    echo "[${timestamp_iso}] #${pad_num} -> HTTP ${http_code} (${latency_ms}ms) [FAILED/OUTAGE]"
  fi

  echo "${timestamp_iso},${epoch_sec},${pad_num},${http_code},${latency_ms},${result}" >> "${LOG_FILE}"

  if [ "${MAX_OBJECTS}" -gt 0 ] && [ "${count}" -ge "${MAX_OBJECTS}" ]; then
    break
  fi

  sleep "${INTERVAL}"
done

cleanup
