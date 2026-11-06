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
  t0_loop="${EPOCHREALTIME:-$(date +%s.%N)}"

  count=$((count + 1))
  pad_num=$(printf "%05d" "${count}")
  obj_key="obj-${pad_num}.txt"
  timestamp_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  epoch_sec=$(date +%s.%N)
  payload="HA Platform Object ${pad_num} written at ${timestamp_iso} via ${PROXY_URL}"
  t1_pre_curl="${EPOCHREALTIME:-$(date +%s.%N)}"

  # Perform PUT request measuring HTTP status code and response time
  resp=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
    --connect-timeout 2 \
    --max-time 5 \
    -X PUT \
    --data-binary "${payload}" \
    "${PROXY_URL}/${BUCKET}/${obj_key}" 2>/dev/null || echo "000 0.000")
  t2_post_curl="${EPOCHREALTIME:-$(date +%s.%N)}"

  http_code=$(echo "${resp}" | awk '{print $1}')
  total_time=$(echo "${resp}" | awk '{print $2}')
  latency_ms=$(awk "BEGIN {printf \"%.1f\", ${total_time} * 1000}")
  t3_post_awk="${EPOCHREALTIME:-$(date +%s.%N)}"

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
  t4_post_log="${EPOCHREALTIME:-$(date +%s.%N)}"

  if [ "${count}" -le 8 ]; then
    step_metrics=$(awk -v t0="$t0_loop" -v t1="$t1_pre_curl" -v t2="$t2_post_curl" -v t3="$t3_post_awk" -v t4="$t4_post_log" 'BEGIN {
      printf "vars=%.2fms curl=%.2fms parse=%.2fms log=%.2fms", (t1-t0)*1000, (t2-t1)*1000, (t3-t2)*1000, (t4-t3)*1000
    }')
    echo "  [INSTRUMENTATION] #${pad_num} | loop_start=${t0_loop} | ${step_metrics}"
  fi

  if [ "${MAX_OBJECTS}" -gt 0 ] && [ "${count}" -ge "${MAX_OBJECTS}" ]; then
    break
  fi

  t5_pre_sleep="${EPOCHREALTIME:-$(date +%s.%N)}"
  sleep "${INTERVAL}"
  t6_post_sleep="${EPOCHREALTIME:-$(date +%s.%N)}"

  if [ "${count}" -le 8 ]; then
    sleep_ms=$(awk -v t5="$t5_pre_sleep" -v t6="$t6_post_sleep" 'BEGIN { printf "%.2f", (t6-t5)*1000 }')
    echo "  [INSTRUMENTATION] #${pad_num} | sleep=${sleep_ms}ms | loop_end=${t6_post_sleep}"
  fi
done

cleanup
