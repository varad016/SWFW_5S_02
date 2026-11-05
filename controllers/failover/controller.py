#!/usr/bin/env python3
"""
Failover Controller Daemon
Continuously monitors Primary Region (minio-a). Upon N consecutive health-check failures,
repoints the Global Nginx Proxy to Secondary Region (minio-b), triggers reload,
and records precise RTO measurements.
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
CHECK_INTERVAL = float(os.getenv("HEALTHCHECK_INTERVAL_SECONDS", "2"))
CONFIG_PATH = os.getenv("CONFIG_PATH", "/etc/nginx/conf.d/nginx.conf")
TEMPLATE_PATH = os.getenv("TEMPLATE_PATH", "/etc/nginx/conf.d/nginx.conf.template")
METRICS_FILE = os.getenv("METRICS_FILE", "/var/log/metrics/failover_rto.log")
FAILURE_TIMESTAMP_FILE = os.getenv("FAILURE_TIMESTAMP_FILE", "/var/log/metrics/failure.timestamp")
DOCKER_SOCKET = os.getenv("DOCKER_SOCKET", "/var/run/docker.sock")
PROXY_CONTAINER_NAME = os.getenv("PROXY_CONTAINER_NAME", "global-proxy")


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


def check_health(url, timeout=1.0):
    """Checks endpoint HTTP status with fast connection timeout."""
    try:
        parsed = urllib.parse.urlparse(url)
        host = parsed.hostname
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        path = parsed.path or "/"

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))

        req = f"HEAD {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: HA-Failover-Controller\r\nConnection: close\r\n\r\n"
        sock.sendall(req.encode())
        data = sock.recv(128)
        sock.close()
        return b"200 OK" in data
    except Exception:
        return False


def write_nginx_config(backend_host, backend_port):
    """Generates new Nginx configuration from template and writes to disk."""
    if not os.path.exists(TEMPLATE_PATH):
        content = (
            f"upstream minio_backend {{\n    server {backend_host}:{backend_port};\n}}\n"
            "server {\n    listen 8000;\n    server_name _;\n"
            "    client_max_body_size 0;\n    proxy_buffering off;\n    proxy_request_buffering off;\n"
            "    location / {\n        proxy_pass http://minio_backend;\n"
            "        proxy_set_header Host $http_host;\n"
            "        proxy_set_header X-Real-IP $remote_addr;\n"
            "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
            "        proxy_set_header X-Forwarded-Proto $scheme;\n"
            "        proxy_connect_timeout 1s;\n        proxy_read_timeout 30s;\n        proxy_send_timeout 30s;\n"
            "    }\n}\n"
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
    """Reads failure timestamp written by chaos scripts if present."""
    if os.path.exists(FAILURE_TIMESTAMP_FILE):
        try:
            with open(FAILURE_TIMESTAMP_FILE, "r") as f:
                val = float(f.read().strip())
                if abs(default_t - val) < 300:
                    return val
        except Exception:
            pass
    return default_t


def log_rto_metric(record):
    """Appends measurement record to metrics file and console."""
    os.makedirs(os.path.dirname(METRICS_FILE), exist_ok=True)
    json_line = json.dumps(record)
    with open(METRICS_FILE, "a") as f:
        f.write(json_line + "\n")
        f.flush()

    print("\n" + "=" * 60, flush=True)
    print(f"[FAILOVER EVENT] {record['event']} -> {record['to']}", flush=True)
    print(f"  Failure Timestamp (T0)   : {record['t_failure']:.4f}", flush=True)
    print(f"  Detection Timestamp (T1) : {record['t_detect']:.4f}", flush=True)
    print(f"  First Success (T2)       : {record['t_first_success']:.4f}", flush=True)
    print(f"  Detection Latency        : {record['detection_latency_seconds']:.3f} s", flush=True)
    print(f"  Switchover Duration      : {record['switchover_seconds']:.3f} s", flush=True)
    print(f"  Total RTO (T2 - T0)      : {record['rto_seconds']:.3f} s", flush=True)
    print("=" * 60 + "\n", flush=True)


def main():
    print("=" * 60, flush=True)
    print("== HA Failover Controller Initializing                  ==", flush=True)
    print(f"   Primary Endpoint : {PRIMARY_ENDPOINT}", flush=True)
    print(f"   Secondary Host   : {SECONDARY_HOST}:{BACKEND_PORT}", flush=True)
    print(f"   Threshold        : {FAILOVER_THRESHOLD} consecutive failures", flush=True)
    print(f"   Probe Interval   : {CHECK_INTERVAL} s", flush=True)
    print("=" * 60, flush=True)

    active_backend = PRIMARY_HOST
    consecutive_failures = 0

    while True:
        is_healthy = check_health(PRIMARY_ENDPOINT, timeout=1.0)

        if is_healthy:
            if consecutive_failures > 0:
                print(f"[HEARTBEAT] Primary {PRIMARY_HOST} recovered. Resetting failure counter.", flush=True)
                consecutive_failures = 0
            # If active_backend was SECONDARY_HOST, we keep it on secondary until explicit failback is requested
        else:
            consecutive_failures += 1
            print(f"[WARNING] Primary {PRIMARY_HOST} healthcheck failed ({consecutive_failures}/{FAILOVER_THRESHOLD})", flush=True)

            if consecutive_failures >= FAILOVER_THRESHOLD and active_backend == PRIMARY_HOST:
                t_detect = time.time()
                t_failure = read_failure_timestamp(t_detect)

                print(f"\n[ALERT] Failure threshold reached ({consecutive_failures} failures). Initiating failover to {SECONDARY_HOST}...", flush=True)

                # 1. Update Nginx Configuration
                write_nginx_config(SECONDARY_HOST, BACKEND_PORT)

                # 2. Trigger Graceful Reload
                reloaded = reload_nginx(PROXY_CONTAINER_NAME)
                print(f"[ACTION] Nginx config updated and reloaded: {reloaded}", flush=True)

                # 3. Poll Global Proxy until first successful request
                t_first_success = None
                poll_start = time.time()
                while time.time() - poll_start < 15:
                    if check_health(GLOBAL_PROXY_URL, timeout=0.5):
                        t_first_success = time.time()
                        break
                    time.sleep(0.05)

                if t_first_success is None:
                    t_first_success = time.time()
                    print("[ERROR] Timeout waiting for global proxy to confirm 200 OK from secondary region.", flush=True)

                detection_latency = max(0.0, t_detect - t_failure)
                switchover_duration = max(0.0, t_first_success - t_detect)
                total_rto = max(0.0, t_first_success - t_failure)

                record = {
                    "event": "FAILOVER_TO_REGION_B",
                    "from": PRIMARY_HOST,
                    "to": SECONDARY_HOST,
                    "t_failure": t_failure,
                    "t_detect": t_detect,
                    "t_first_success": t_first_success,
                    "detection_latency_seconds": round(detection_latency, 4),
                    "switchover_seconds": round(switchover_duration, 4),
                    "rto_seconds": round(total_rto, 4),
                    "iso_timestamp": datetime.now(timezone.utc).isoformat()
                }

                log_rto_metric(record)
                active_backend = SECONDARY_HOST

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
