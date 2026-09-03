#!/usr/bin/env python3
"""
k8s-metrics-logger

Polls the metrics.k8s.io API and appends normalized CSV rows:
timestamp,namespace,pod,cpu_m,mem_Mi

Adds a lightweight HTTP server exposing:
 - /healthz  (liveness)
 - /readyz   (readiness based on last successful poll)
 - /metrics  (Prometheus-style metrics with last-run stats)
"""
import os
import re
import time
import csv
import logging
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from kubernetes import client, config
from kubernetes.client.rest import ApiException

# Configuration from environment
INTERVAL = int(os.getenv("INTERVAL", "60"))
OUTFILE = os.getenv("OUTFILE", "/data/k8s_metrics.csv")
NAMESPACE = os.getenv("NAMESPACE", "")  # empty = all namespaces
POD_REGEX = os.getenv("POD_REGEX", "")  # empty = no filtering
TRY_INCLUSTER_FIRST = os.getenv("TRY_INCLUSTER_FIRST", "true").lower() in ("1", "true", "yes")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8080"))
# readiness: consider ready if last successful poll was within READY_THRESHOLD_SECONDS
READY_THRESHOLD_SECONDS = int(os.getenv("READY_THRESHOLD_SECONDS", str(INTERVAL * 3)))

# Setup logging, including a custom TRACE level
TRACE_LEVEL_NUM = 5
logging.addLevelName(TRACE_LEVEL_NUM, "TRACE")


def _trace(self, message, *args, **kws):
    if self.isEnabledFor(TRACE_LEVEL_NUM):
        self._log(TRACE_LEVEL_NUM, message, args, **kws)


logging.Logger.trace = _trace


def configure_logging(level_name: str = "INFO"):
    level_name = (level_name or "INFO").upper()
    level_map = {
        "CRITICAL": logging.CRITICAL,
        "FATAL": logging.CRITICAL,
        "ERROR": logging.ERROR,
        "WARN": logging.WARNING,
        "WARNING": logging.WARNING,
        "INFO": logging.INFO,
        "DEBUG": logging.DEBUG,
        "TRACE": TRACE_LEVEL_NUM,
    }
    level = level_map.get(level_name, logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return logging.getLogger("k8s-metrics-logger")


logger = configure_logging(LOG_LEVEL)

pod_filter = None
if POD_REGEX:
    try:
        pod_filter = re.compile(POD_REGEX)
        logger.debug("Compiled pod regex filter: %s", POD_REGEX)
    except re.error as e:
        logger.error("Invalid POD_REGEX '%s': %s", POD_REGEX, e)
        pod_filter = None

# Shared runtime stats for /metrics and readiness
stats_lock = threading.Lock()
stats = {
    "polls_total": 0,
    "last_success_unix": 0.0,
    "last_poll_duration_seconds": 0.0,
    "last_rows": 0,
    "last_error": 0,  # 0 = none, 1 = error in last poll
}


# unit helpers
def cpu_to_millicores(s: str) -> float:
    s = str(s).strip()
    if s == "0":
        logger.trace("cpu_to_millicores: input '0' -> 0.0")
        return 0.0
    if s.endswith("n"):  # nanocores
        try:
            n = float(s[:-1])
            val = n / 1e6
            logger.trace("cpu_to_millicores: %s -> %f m", s, val)
            return val
        except Exception:
            logger.debug("Failed parsing nanocores CPU string: %s", s, exc_info=True)
            return 0.0
    if s.endswith("u"):  # microcores
        try:
            u = float(s[:-1])
            val = u / 1000.0
            logger.trace("cpu_to_millicores: %s -> %f m", s, val)
            return val
        except Exception:
            logger.debug("Failed parsing microcores CPU string: %s", s, exc_info=True)
            return 0.0
    if s.endswith("m"):
        try:
            val = float(s[:-1])
            logger.trace("cpu_to_millicores: %s -> %f m", s, val)
            return val
        except Exception:
            logger.debug("Failed parsing millicores CPU string: %s", s, exc_info=True)
            return 0.0
    # otherwise assume cores
    try:
        val = float(s) * 1000.0
        logger.trace("cpu_to_millicores: %s cores -> %f m", s, val)
        return val
    except Exception:
        logger.debug("Failed parsing CPU string as cores: %s", s, exc_info=True)
        return 0.0


def mem_to_Mi(s: str) -> float:
    s = str(s).strip()
    m = re.match(r"^([0-9.]+)(Ki|Mi|Gi|Ti|K|M|G|T)?$", s)
    if not m:
        try:
            val = float(s) / (1024 * 1024)
            logger.trace("mem_to_Mi: assumed bytes %s -> %f Mi", s, val)
            return val
        except Exception:
            logger.debug("Failed parsing memory string: %s", s, exc_info=True)
            return 0.0
    val = float(m.group(1))
    unit = m.group(2)
    if not unit:
        res = val / (1024 * 1024)
        logger.trace("mem_to_Mi: no unit %s -> %f Mi", s, res)
        return res
    unit = unit.strip()
    if unit in ("Ki", "K"):
        res = val / 1024.0
        logger.trace("mem_to_Mi: %s -> %f Mi", s, res)
        return res
    if unit in ("Mi", "M"):
        logger.trace("mem_to_Mi: %s -> %f Mi", s, val)
        return val
    if unit in ("Gi", "G"):
        res = val * 1024.0
        logger.trace("mem_to_Mi: %s -> %f Mi", s, res)
        return res
    if unit in ("Ti", "T"):
        res = val * 1024.0 * 1024.0
        logger.trace("mem_to_Mi: %s -> %f Mi", s, res)
        return res
    res = val / (1024 * 1024)
    logger.trace("mem_to_Mi fallback: %s -> %f Mi", s, res)
    return res


def ensure_header(path):
    if not os.path.exists(path):
        d = os.path.dirname(path)
        if d and not os.path.exists(d):
            os.makedirs(d, exist_ok=True)
        with open(path, "w") as f:
            f.write("timestamp,namespace,pod,cpu_m,mem_Mi\n")
        logger.info("Created metrics CSV with header: %s", path)


def try_load_config():
    loaded = False
    if TRY_INCLUSTER_FIRST:
        logger.debug("TRY_INCLUSTER_FIRST is true; attempting in-cluster config first")
        try:
            config.load_incluster_config()
            loaded = True
            logger.info("Loaded in-cluster kube config")
        except Exception:
            logger.debug("In-cluster config failed; trying local kubeconfig", exc_info=True)
            try:
                config.load_kube_config()
                loaded = True
                logger.info("Loaded local kube config (~/.kube/config)")
            except Exception as e:
                logger.error("Failed to load kube config (in-cluster then local): %s", e, exc_info=True)
                loaded = False
    else:
        logger.debug("TRY_INCLUSTER_FIRST is false; attempting local kubeconfig first")
        try:
            config.load_kube_config()
            loaded = True
            logger.info("Loaded local kube config (~/.kube/config)")
        except Exception:
            logger.debug("Local kubeconfig failed; trying in-cluster", exc_info=True)
            try:
                config.load_incluster_config()
                loaded = True
                logger.info("Loaded in-cluster kube config")
            except Exception as e:
                logger.error("Failed to load kube config (local then in-cluster): %s", e, exc_info=True)
                loaded = False
    if not loaded:
        logger.critical("Could not load Kubernetes configuration (in-cluster or kubeconfig).")
        raise RuntimeError("Could not load Kubernetes configuration (in-cluster or kubeconfig).")
    return loaded


def fetch_pod_metrics():
    api = client.CustomObjectsApi()
    try:
        resp = api.list_cluster_custom_object(group="metrics.k8s.io", version="v1beta1", plural="pods")
    except ApiException as e:
        logger.error("API exception fetching metrics: %s", e, exc_info=True)
        raise
    items = resp.get("items", [])
    logger.debug("Fetched %d pod metrics items from metrics API", len(items))
    rows = []
    for it in items:
        meta = it.get("metadata", {})
        ns = meta.get("namespace", "")
        pod = meta.get("name", "")
        if NAMESPACE and ns != NAMESPACE:
            logger.trace("Skipping pod %s/%s due to NAMESPACE filter", ns, pod)
            continue
        if pod_filter and not pod_filter.search(pod):
            logger.trace("Skipping pod %s/%s due to POD_REGEX filter", ns, pod)
            continue
        cpu_total_m = 0.0
        mem_total_Mi = 0.0
        for c in it.get("containers", []):
            usage = c.get("usage", {})
            cpu = usage.get("cpu", "0")
            mem = usage.get("memory", "0")
            cpu_m = cpu_to_millicores(cpu)
            mem_mi = mem_to_Mi(mem)
            logger.trace(
                "Pod %s/%s container %s usage cpu=%s(%f m) mem=%s(%f Mi)",
                ns,
                pod,
                c.get("name", "<unknown>"),
                cpu,
                cpu_m,
                mem,
                mem_mi,
            )
            cpu_total_m += cpu_m
            mem_total_Mi += mem_mi
        logger.debug("Pod %s/%s total cpu=%f m mem=%f Mi", ns, pod, cpu_total_m, mem_total_Mi)
        rows.append((ns, pod, cpu_total_m, mem_total_Mi))
    return rows


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if self.path == "/readyz":
            with stats_lock:
                last_success = stats["last_success_unix"]
            if last_success and (time.time() - last_success) <= READY_THRESHOLD_SECONDS:
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"ready\n")
            else:
                self.send_response(503)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"not ready\n")
            return
        if self.path == "/metrics":
            # Prometheus exposition format (basic)
            with stats_lock:
                st = dict(stats)
            lines = []
            lines.append('# HELP k8s_metrics_logger_polls_total Total number of polls performed')
            lines.append('# TYPE k8s_metrics_logger_polls_total counter')
            lines.append(f'k8s_metrics_logger_polls_total {st["polls_total"]}')
            lines.append('# HELP k8s_metrics_logger_last_success_unix_seconds Last successful poll timestamp (unix seconds)')
            lines.append('# TYPE k8s_metrics_logger_last_success_unix_seconds gauge')
            lines.append(f'k8s_metrics_logger_last_success_unix_seconds {st["last_success_unix"]}')
            lines.append('# HELP k8s_metrics_logger_last_poll_duration_seconds Duration of last poll in seconds')
            lines.append('# TYPE k8s_metrics_logger_last_poll_duration_seconds gauge')
            lines.append(f'k8s_metrics_logger_last_poll_duration_seconds {st["last_poll_duration_seconds"]}')
            lines.append('# HELP k8s_metrics_logger_last_rows Number of rows written in last poll')
            lines.append('# TYPE k8s_metrics_logger_last_rows gauge')
            lines.append(f'k8s_metrics_logger_last_rows {st["last_rows"]}')
            lines.append('# HELP k8s_metrics_logger_last_error 1 if last poll errored, 0 otherwise')
            lines.append('# TYPE k8s_metrics_logger_last_error gauge')
            lines.append(f'k8s_metrics_logger_last_error {st["last_error"]}')
            body = "\n".join(lines) + "\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
            return
        # default: 404
        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"not found\n")

    # route HTTP library logs into our logger
    def log_message(self, format, *args):
        logger.debug("HTTP %s - %s" % (self.address_string(), format % args))


def start_http_server(port: int = METRICS_PORT):
    server = ThreadingHTTPServer(("0.0.0.0", port), MetricsHandler)
    t = threading.Thread(target=server.serve_forever, daemon=True, name="metrics-http-server")
    t.start()
    logger.info("Started HTTP metrics server on port %d", port)
    return server


def main_loop():
    ensure_header(OUTFILE)
    try_load_config()
    start_http_server(METRICS_PORT)
    logger.info(
        "Starting main loop: INTERVAL=%s OUTFILE=%s NAMESPACE=%s POD_REGEX=%s LOG_LEVEL=%s METRICS_PORT=%s READY_THRESHOLD_SECONDS=%s",
        INTERVAL,
        OUTFILE,
        NAMESPACE or "<all>",
        POD_REGEX or "<none>",
        LOG_LEVEL,
        METRICS_PORT,
        READY_THRESHOLD_SECONDS,
    )
    while True:
        start = time.time()
        try:
            rows = fetch_pod_metrics()
            duration = time.time() - start
            rows_written = 0
            if rows:
                ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                with open(OUTFILE, "a", newline="") as f:
                    writer = csv.writer(f)
                    for ns, pod, cpu_m, mem_Mi in rows:
                        writer.writerow([ts, ns, pod, f"{cpu_m:.3f}", f"{mem_Mi:.3f}"])
                        rows_written += 1
                logger.info("Appended %d rows to %s", rows_written, OUTFILE)
                logger.trace("Last timestamp written: %s", ts)
            else:
                logger.debug("No rows fetched from metrics API on this poll")
            with stats_lock:
                stats["polls_total"] += 1
                stats["last_success_unix"] = time.time()
                stats["last_poll_duration_seconds"] = duration
                stats["last_rows"] = rows_written
                stats["last_error"] = 0
        except Exception as e:
            duration = time.time() - start
            logger.exception("Error during poll loop: %s", e)
            with stats_lock:
                stats["polls_total"] += 1
                stats["last_poll_duration_seconds"] = duration
                stats["last_error"] = 1
        time.sleep(INTERVAL)


if __name__ == "__main__":
    logger.info(
        "k8s-metrics-logger starting: INTERVAL=%s OUTFILE=%s NAMESPACE=%s POD_REGEX=%s TRY_INCLUSTER_FIRST=%s LOG_LEVEL=%s METRICS_PORT=%s READY_THRESHOLD_SECONDS=%s",
        INTERVAL,
        OUTFILE,
        NAMESPACE or "<all>",
        POD_REGEX or "<none>",
        TRY_INCLUSTER_FIRST,
        LOG_LEVEL,
        METRICS_PORT,
        READY_THRESHOLD_SECONDS,
    )
    main_loop()
