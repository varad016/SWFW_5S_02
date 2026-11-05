#!/usr/bin/env python3
"""
Failover Controller Daemon
Monitors Primary Region (minio-a) via HTTP GET /minio/health/live (expecting 200 OK).
Uses static IP literal targeting to prevent glibc getaddrinfo DNS timeouts when the container dies.
Logs per-probe start time, duration, and error type.
Upon N consecutive probe failures, repoints the Global Nginx Proxy to Secondary Region (minio-b),
triggers Nginx reload via the Docker socket, and logs RTO measurements.
"""

import os
import sys
import time
import json
import socket
import http.client
import urllib.parse
from datetime import datetime, timezone

PRIMARY_ENDPOINT = os.getenv("PRIMARY_ENDPOINT", "http://minio-a:9000/minio/health/live")
SECONDARY_HOST = os.getenv("SECONDARY_HOST", "minio-b")
PRIMARY_HOST = os.getenv("PRIMARY_HOST", "minio-a")
BACKEND_PORT = int(os.getenv("BACKEND_PORT", "9000"))
GLOBAL_PROXY_URL = os.getenv("GLOBAL_PROXY_URL", "http://global-proxy:8000/minio/health/live")
FAILOVER_THRESHOLD = int(os.getenv("FAILOVER_THRESHOLD", "3"))
CHECK_INTERVAL = float(os.getenv("HEALTHCHECK_INTERVAL_SECONDS", "1.0"))
PROBE_TIMEOUT = float(os.getenv("PROBE_TIMEOUT_SECONDS", "0.5"))
BUCKET_NAME = os.getenv("BUCKET_NAME", "data-bucket")
CONFIG_PATH = os.getenv("CONFIG_PATH", "/etc/nginx/conf.d/nginx.conf")
TEMPLATE_PATH = os.getenv("TEMPLATE_PATH", "/etc/nginx/conf.d/nginx.conf.template")
METRICS_FILE = os.getenv("METRICS_FILE", "/var/log/metrics/failover_rto.log")
PROBE_LOG_FILE = os.getenv("PROBE_LOG_FILE", "/var/log/metrics/probe_trace.log")
FAILURE_TIMESTAMP_FILE = os.getenv("FAILURE_TIMESTAMP_FILE", "/var/log/metrics/failure.timestamp")
DOCKER_SOCKET = os.getenv("DOCKER_SOCKET", "/var/run/docker.sock")
PROXY_CONTAINER_NAME = os.getenv("PROXY_CONTAINER_NAME", "global-proxy")

PRIMARY_IP = None


class UnixSocketHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path):
        super().__init__("localhost")
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.socket_path)


def reload_nginx(container_name):
    """Reloads Nginx by sending SIGHUP via the Docker Unix socket."""
    try:
        conn = UnixSocketHTTPConnection(DOCKER_SOCKET)
        conn.request("POST", f"/containers/{container_name}/kill?signal=HUP")
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp.status in (200, 204)
    except Exception as e:
        print(f"[ERROR] Failed to reload Nginx via Docker socket: {e}", flush=True)
        return False


def docker_exec(container_name, cmd):
    """Executes a command inside a target container via the Docker Unix socket."""
    try:
        conn = UnixSocketHTTPConnection(DOCKER_SOCKET)
        exec_body = json.dumps({"AttachStdout": True, "AttachStderr": True, "Cmd": cmd})
        conn.request("POST", f"/containers/{container_name}/exec", body=exec_body, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = json.loads(resp.read().decode())
        exec_id = data.get("Id")
        if not exec_id:
            conn.close()
            return False
        start_body = json.dumps({"Detach": False, "Tty": False})
        conn.request("POST", f"/exec/{exec_id}/start", body=start_body, headers={"Content-Type": "application/json"})
        conn.getresponse().read()
        conn.close()
        return True
    except Exception as e:
        print(f"[WARN] Failed to exec {cmd} in {container_name}: {e}", flush=True)
        return False


def get_or_resolve_primary_ip():
    """Resolves primary IP once and caches it permanently to avoid DNS delays on dead containers."""
    global PRIMARY_IP
    if PRIMARY_IP:
        return PRIMARY_IP
    for _ in range(30):
        try:
            ip = socket.gethostbyname(PRIMARY_HOST)
            PRIMARY_IP = ip
            return ip
        except Exception:
            time.sleep(0.5)
    return PRIMARY_HOST


def check_health_http(url, timeout=0.5, is_primary=True):
    """
    Performs HTTP GET request expecting 200 OK.
    Returns (is_healthy, duration_ms, error_type).
    """
    t_start = time.time()
    parsed = urllib.parse.urlparse(url)
    hostname = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/minio/health/live"

    target_host = get_or_resolve_primary_ip() if is_primary else hostname

    try:
        # Connecting to IP literal avoids getaddrinfo DNS resolution
        conn = http.client.HTTPConnection(target_host, port, timeout=timeout)
        conn.request("GET", path, headers={"Host": f"{hostname}:{port}", "User-Agent": "HA-Failover-Controller/1.0"})
        resp = conn.getresponse()
        status = resp.status
        resp.read()
        conn.close()
        duration_ms = (time.time() - t_start) * 1000.0
        if status == 200:
            return True, duration_ms, "None"
        return False, duration_ms, f"HTTP_{status}"
    except Exception as e:
        duration_ms = (time.time() - t_start) * 1000.0
        return False, duration_ms, type(e).__name__


def write_nginx_config(backend_host, backend_port):
    """Generates new Nginx configuration from template and writes to disk."""
    if not os.path.exists(TEMPLATE_PATH):
        content = (
            "server {\n"
            "    listen 8000;\n"
            "    server_name _;\n"
            "    resolver 127.0.0.11 valid=2s ipv6=off;\n"
            f"    set $backend_upstream http://{backend_host}:{backend_port};\n"
            "    client_max_body_size 0;\n"
            "    proxy_buffering off;\n"
            "    proxy_request_buffering off;\n"
            "    location / {\n"
            "        proxy_pass $backend_upstream;\n"
            "        proxy_set_header Host $http_host;\n"
            "        proxy_set_header X-Real-IP $remote_addr;\n"
            "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
            "        proxy_set_header X-Forwarded-Proto $scheme;\n"
            "        proxy_connect_timeout 1s;\n"
            "        proxy_read_timeout 30s;\n"
            "        proxy_send_timeout 30s;\n"
            "    }\n"
            "}\n"
        )
    else:
        with open(TEMPLATE_PATH, "r") as f:
            template = f.read()
        content = template.replace("${BACKEND_HOST}", backend_host).replace("${BACKEND_PORT}", str(backend_port))

    with open(CONFIG_PATH, "w") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())


def read_failure_timestamp(default_t):
    """Reads crash failure timestamp recorded by chaos scripts."""
    if os.path.exists(FAILURE_TIMESTAMP_FILE):
        try:
            with open(FAILURE_TIMESTAMP_FILE, "r") as f:
                val = float(f.read().strip())
                if abs(default_t - val) < 300:
                    return val
        except Exception:
            pass
    return default_t


def log_probe(probe_index, t_probe, duration_ms, is_healthy, err_type):
    """Logs individual probe trace to file and console."""
    status_str = "OK" if is_healthy else "FAIL"
    log_line = (
        f"probe_index={probe_index} timestamp={t_probe:.4f} "
        f"status={status_str} duration_ms={duration_ms:.2f} error={err_type}"
    )
    print(f"[PROBE TRACE] {log_line}", flush=True)

    try:
        os.makedirs(os.path.dirname(PROBE_LOG_FILE), exist_ok=True)
        with open(PROBE_LOG_FILE, "a") as f:
            f.write(log_line + "\n")
    except Exception:
        pass


def log_rto_metric(record):
    """Appends measurement record to metrics file and console."""
    os.makedirs(os.path.dirname(METRICS_FILE), exist_ok=True)
    json_line = json.dumps(record)
    with open(METRICS_FILE, "a") as f:
        f.write(json_line + "\n")
        f.flush()

    print("\n" + "=" * 60, flush=True)
    print(f"[FAILOVER EVENT] {record['event']} -> {record['to']}", flush=True)
    print(f"  Failure Timestamp (T_failure)        : {record['t_failure']:.4f}", flush=True)
    print(f"  First Failed Probe (T_first_fail)    : {record['t_first_fail']:.4f}", flush=True)
    print(f"  Detection Timestamp (T_detect)       : {record['t_detect']:.4f}", flush=True)
    print(f"  First Success Through Proxy (T_succ) : {record['t_first_success']:.4f}", flush=True)
    print(f"  Detection Latency (T_detect - T_fail): {record['detection_latency_from_failure_seconds']:.3f} s", flush=True)
    print(f"  Detection From First Fail            : {record['detection_latency_from_first_fail_seconds']:.3f} s", flush=True)
    print(f"  Switchover Time (T_succ - T_detect)  : {record['switchover_duration_seconds']:.3f} s", flush=True)
    print(f"  Total RTO (T_succ - T_fail)          : {record['total_rto_seconds']:.3f} s", flush=True)
    print("=" * 60 + "\n", flush=True)


def main():
    print("=" * 60, flush=True)
    print("== HA Failover Controller Initializing (Tightened HTTP) ==", flush=True)
    print(f"   Primary Endpoint : {PRIMARY_ENDPOINT} (expecting HTTP 200)", flush=True)
    print(f"   Secondary Host   : {SECONDARY_HOST}:{BACKEND_PORT}", flush=True)
    print(f"   Threshold (N)    : {FAILOVER_THRESHOLD} consecutive failures", flush=True)
    print(f"   Probe Interval   : {CHECK_INTERVAL} s", flush=True)
    print(f"   Probe Timeout    : {PROBE_TIMEOUT} s", flush=True)
    print("=" * 60, flush=True)

    # Initial IP resolution
    resolved_ip = get_or_resolve_primary_ip()
    print(f"   Locked Primary IP: {resolved_ip}", flush=True)

    active_backend = PRIMARY_HOST
    consecutive_failures = 0
    t_first_fail = None
    probe_counter = 0

    while True:
        probe_counter += 1
        t_probe = time.time()
        is_healthy, duration_ms, err_type = check_health_http(
            PRIMARY_ENDPOINT, timeout=PROBE_TIMEOUT, is_primary=True
        )

        if not is_healthy:
            log_probe(probe_counter, t_probe, duration_ms, is_healthy, err_type)

        if is_healthy:
            if consecutive_failures > 0:
                print(f"[HEARTBEAT] Primary {PRIMARY_HOST} healthy. Resetting failure counter.", flush=True)
                consecutive_failures = 0
                t_first_fail = None
        else:
            if consecutive_failures == 0:
                t_first_fail = t_probe
                print(f"[WARNING] First probe failure detected on {PRIMARY_HOST} at {t_first_fail:.4f}", flush=True)

            consecutive_failures += 1
            print(f"[WARNING] Primary {PRIMARY_HOST} probe failed ({consecutive_failures}/{FAILOVER_THRESHOLD})", flush=True)

            if consecutive_failures >= FAILOVER_THRESHOLD and active_backend == PRIMARY_HOST:
                t_detect = time.time()
                t_failure = read_failure_timestamp(t_first_fail or t_detect)

                print(f"\n[ALERT] Failure threshold reached ({consecutive_failures} failures). Initiating failover to {SECONDARY_HOST}...", flush=True)

                # 1. Update Nginx Configuration
                write_nginx_config(SECONDARY_HOST, BACKEND_PORT)

                # 2. Trigger Graceful Reload
                reloaded = reload_nginx(PROXY_CONTAINER_NAME)
                print(f"[ACTION] Nginx config updated and reloaded: {reloaded}", flush=True)

                # 3. Demote secondary to standalone mode (remove replication rule so writes never block)
                print(f"[FAILOVER] Removing replication rule on {SECONDARY_HOST} to ensure unblocked standalone writes...", flush=True)
                demoted = docker_exec(SECONDARY_HOST, ["mc", "replicate", "rm", f"local/{BUCKET_NAME}", "--all", "--force"])
                print(f"[ACTION] Replication rule removed on {SECONDARY_HOST}: {demoted}", flush=True)

                # 4. Poll Global Proxy until first successful request
                t_first_success = None
                poll_start = time.time()
                while time.time() - poll_start < 15:
                    succ, p_dur, p_err = check_health_http(GLOBAL_PROXY_URL, timeout=0.3, is_primary=False)
                    if succ:
                        t_first_success = time.time()
                        break
                    time.sleep(0.05)

                if t_first_success is None:
                    t_first_success = time.time()
                    print("[ERROR] Timeout waiting for global proxy to confirm 200 OK from secondary region.", flush=True)

                det_from_failure = max(0.0, t_detect - t_failure)
                det_from_first_fail = max(0.0, t_detect - (t_first_fail or t_detect))
                switchover_duration = max(0.0, t_first_success - t_detect)
                total_rto = max(0.0, t_first_success - t_failure)

                record = {
                    "event": "FAILOVER_TO_REGION_B",
                    "from": PRIMARY_HOST,
                    "to": SECONDARY_HOST,
                    "t_failure": t_failure,
                    "t_first_fail": t_first_fail,
                    "t_detect": t_detect,
                    "t_first_success": t_first_success,
                    "detection_latency_from_failure_seconds": round(det_from_failure, 4),
                    "detection_latency_from_first_fail_seconds": round(det_from_first_fail, 4),
                    "switchover_duration_seconds": round(switchover_duration, 4),
                    "total_rto_seconds": round(total_rto, 4),
                    "iso_timestamp": datetime.now(timezone.utc).isoformat()
                }

                log_rto_metric(record)
                active_backend = SECONDARY_HOST

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
