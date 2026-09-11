#!/usr/bin/env python3
"""
k8s-metrics-logger

Polls the metrics.k8s.io API and appends normalized CSV rows:
    timestamp,namespace,pod,cpu_m,mem_Mi

HTTP endpoints:
 - GET /healthz
     Liveness probe. Returns 200 OK if server running.

 - GET /readyz
     Readiness probe. Returns 200 OK when the last successful poll was within READY_THRESHOLD_SECONDS.

 - GET /metrics
     Prometheus-style metrics about the poller (polls_total, last_success_unix_seconds,
     last_poll_duration_seconds, last_rows, last_error).

 - GET /csv
     Download CSV. Supports optional ISO8601 date range and rotated-file inclusion:
       Query parameters:
         start=<ISO8601>  e.g. 2026-09-03T00:00:00 or 2026-09-03T00:00:00Z or with offset
         end=<ISO8601>
         include_rotated=true|false  (default false) - when true, rotated backup files
             (OUTFILE.YYYYMMDD_HHMMSS and .gz) are also scanned so ranges spanning rotations
             are covered.
     Examples:
       Full file:
         curl -sS http://127.0.0.1:8080/csv -o k8s_metrics.csv
       Range (no rotated files):
         curl -G --data-urlencode "start=2026-09-03T00:00:00" --data-urlencode "end=2026-09-10T00:00:00" \
           http://127.0.0.1:8080/csv -o range.csv
       Range including rotated backups:
         curl -G --data-urlencode "start=2026-09-03T00:00:00" --data-urlencode "end=2026-09-10T00:00:00" \
           --data-urlencode "include_rotated=true" http://127.0.0.1:8080/csv -o range_with_rotated.csv

Rotation behavior (size-based):
 - When OUTFILE >= ROTATE_MAX_BYTES, OUTFILE is atomically renamed to OUTFILE.YYYYMMDD_HHMMSS.
 - If ROTATE_COMPRESS=true an asynchronous background thread compresses the rotated file to .gz.
 - ROTATE_MAX_BACKUPS most recent backups are retained; older ones are pruned (pruning skips files currently being compressed).
 - Rotation is triggered in the poll loop before appending new rows.

Environment variables (defaults shown):
 - INTERVAL=60
 - OUTFILE=/data/k8s_metrics.csv
 - NAMESPACE=           (empty = all)
 - POD_REGEX=           (empty = no filter)
 - TRY_INCLUSTER_FIRST=true
 - LOG_LEVEL=INFO       (supports TRACE, DEBUG, INFO, WARN, ERROR)
 - METRICS_PORT=8080
 - READY_THRESHOLD_SECONDS = INTERVAL*3
 - CHUNK_SIZE = 65536   (CSV stream chunk size)
 - ROTATE_MAX_BYTES = 104857600  (100 MiB)
 - ROTATE_MAX_BACKUPS = 7
 - ROTATE_COMPRESS = false  (set to "true" to enable async compression)

"""
import os
import re
import time
import csv
import logging
import threading
import sys
import shutil
import glob
import gzip
import urllib.parse
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
READY_THRESHOLD_SECONDS = int(os.getenv("READY_THRESHOLD_SECONDS", str(INTERVAL * 3)))
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", str(64 * 1024)))  # bytes

# Rotation settings
ROTATE_MAX_BYTES = int(os.getenv("ROTATE_MAX_BYTES", str(100 * 1024 * 1024)))  # 100 MiB
ROTATE_MAX_BACKUPS = int(os.getenv("ROTATE_MAX_BACKUPS", "7"))
ROTATE_COMPRESS = os.getenv("ROTATE_COMPRESS", "false").lower() in ("1", "true", "yes")

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

    logger = logging.getLogger("k8s-metrics-logger")
    logger.setLevel(level)
    # ensure stdout StreamHandler exists
    if not any(isinstance(h, logging.StreamHandler) and getattr(h, "stream", None) is sys.stdout for h in logger.handlers):
        sh = logging.StreamHandler(stream=sys.stdout)
        sh.setLevel(level)
        fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
        sh.setFormatter(fmt)
        logger.addHandler(sh)
    logger.propagate = False
    return logger


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

# Rotation helpers: asynchronous compression
compressing_files = set()
compressing_lock = threading.Lock()


def _rotated_filename(timestamp_str: str) -> str:
    return f"{OUTFILE}.{timestamp_str}"


def _prune_rotated_backups():
    """
    Keep only the newest ROTATE_MAX_BACKUPS rotated files (including .gz variants),
    skip files currently being compressed.
    """
    base_pattern = OUTFILE + ".*"
    items = sorted(glob.glob(base_pattern), key=os.path.getmtime, reverse=True)
    if not items:
        return
    with compressing_lock:
        in_progress = set(compressing_files)
    filtered_items = [p for p in items if p not in in_progress]
    if len(filtered_items) <= ROTATE_MAX_BACKUPS:
        return
    to_remove = filtered_items[ROTATE_MAX_BACKUPS:]
    for p in to_remove:
        try:
            os.remove(p)
            logger.info("Pruned old rotated file: %s", p)
        except Exception:
            logger.exception("Failed to remove rotated backup: %s", p)


def _compress_file_async(path: str):
    """
    Start a background thread to compress the given path (path -> path.gz) and remove original.
    After compression completes it triggers pruning.
    """

    def worker(p):
        logger.debug("Async compress worker started for %s", p)
        with compressing_lock:
            compressing_files.add(p)
        try:
            gz_path = p + ".gz"
            try:
                with open(p, "rb") as f_in, gzip.open(gz_path, "wb") as f_out:
                    shutil.copyfileobj(f_in, f_out)
                try:
                    os.remove(p)
                except Exception:
                    logger.exception("Failed to remove original rotated file after compression: %s", p)
                logger.info("Async compressed rotated file: %s -> %s", p, gz_path)
            except Exception:
                logger.exception("Async compression failed for %s", p)
        finally:
            with compressing_lock:
                compressing_files.discard(p)
            try:
                _prune_rotated_backups()
            except Exception:
                logger.exception("Error pruning rotated backups after async compression")

    t = threading.Thread(target=worker, args=(path,), daemon=True, name=f"compress-{os.path.basename(path)}")
    t.start()
    logger.debug("Started async compression thread for %s (thread %s)", path, t.name)


def rotate_csv_if_needed():
    """
    If OUTFILE exists and is >= ROTATE_MAX_BYTES, rotate it:
     - rename to OUTFILE.YYYYMMDD_HHMMSS
     - optionally compress asynchronously (ROTATE_COMPRESS)
     - prune older backups to ROTATE_MAX_BACKUPS (skipping files being compressed)
     - create a fresh OUTFILE with header (ensure_header)
    """
    try:
        if not os.path.exists(OUTFILE):
            return
        try:
            size = os.path.getsize(OUTFILE)
        except OSError:
            logger.debug("Could not stat OUTFILE for rotation: %s", OUTFILE)
            return
        if size < ROTATE_MAX_BYTES:
            return

        ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        rotated = _rotated_filename(ts)
        logger.info("Rotating CSV %s (size=%d bytes) -> %s", OUTFILE, size, rotated)

        try:
            # atomic move
            shutil.move(OUTFILE, rotated)
        except Exception:
            logger.exception("Failed to rotate file %s -> %s", OUTFILE, rotated)
            return

        if ROTATE_COMPRESS:
            try:
                _compress_file_async(rotated)
            except Exception:
                logger.exception("Failed to start async compression for %s", rotated)
        else:
            try:
                _prune_rotated_backups()
            except Exception:
                logger.exception("Error pruning rotated backups")
        try:
            ensure_header(OUTFILE)
        except Exception:
            logger.exception("Error creating new OUTFILE after rotation: %s", OUTFILE)
    except Exception:
        logger.exception("Unexpected error in rotate_csv_if_needed")


# unit helpers for metric parsing
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
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        d = os.path.dirname(path)
        if d and not os.path.exists(d):
            os.makedirs(d, exist_ok=True)
        try:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write("timestamp,namespace,pod,cpu_m,mem_Mi\n")
            logger.info("Created metrics CSV with header: %s", path)
        except Exception:
            logger.exception("Failed to create CSV header: %s", path)
            raise


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
        # /healthz
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        # /readyz
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

        # /metrics
        if self.path == "/metrics":
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

        # /csv with optional ISO8601 start/end and include_rotated flag
        if self.path.startswith("/csv"):
            parsed = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(parsed.query)
            start_str = qs.get("start", [None])[0]
            end_str = qs.get("end", [None])[0]
            include_rotated_raw = qs.get("include_rotated", ["false"])[0].lower()
            include_rotated = include_rotated_raw in ("1", "true", "yes")

            def parse_iso8601_to_utc(s):
                if not s:
                    return None
                s2 = s.strip()
                if s2.endswith("Z"):
                    s2 = s2[:-1] + "+00:00"
                try:
                    dt = datetime.fromisoformat(s2)
                except Exception:
                    return "BAD"
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return dt.astimezone(timezone.utc)

            start_dt = parse_iso8601_to_utc(start_str)
            end_dt = parse_iso8601_to_utc(end_str)
            if start_dt == "BAD" or end_dt == "BAD":
                self.send_response(400)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"invalid start/end datetime; use ISO8601 YYYY-MM-DDThh:mm:ss optionally with Z or offset\n")
                logger.debug("CSV range request with invalid datetime: start=%s end=%s", start_str, end_str)
                return

            if not os.path.exists(OUTFILE):
                self.send_response(404)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"not found\n")
                logger.debug("CSV requested but file missing: %s", OUTFILE)
                return

            # Fast full-file case (no range, no rotated)
            if not start_dt and not end_dt and not include_rotated:
                try:
                    file_size = os.path.getsize(OUTFILE)
                    self.send_response(200)
                    self.send_header("Content-Type", "text/csv")
                    self.send_header("Content-Disposition", f'attachment; filename="{os.path.basename(OUTFILE)}"')
                    self.send_header("Content-Length", str(file_size))
                    self.end_headers()
                    with open(OUTFILE, "rb") as fh:
                        chunk = fh.read(CHUNK_SIZE)
                        while chunk:
                            self.wfile.write(chunk)
                            chunk = fh.read(CHUNK_SIZE)
                    logger.info("Served full CSV %s to %s (chunk_size=%d)", OUTFILE, self.client_address, CHUNK_SIZE)
                except Exception:
                    logger.exception("Failed to serve CSV file: %s", OUTFILE)
                    try:
                        if not self.wfile.closed:
                            self.send_response(500)
                            self.send_header("Content-Type", "text/plain")
                            self.end_headers()
                            self.wfile.write(b"internal server error\n")
                    except Exception:
                        pass
                return

            # Build list of files to scan (rotated oldest -> newest then current OUTFILE)
            files_to_scan = []
            if include_rotated:
                base_pattern = OUTFILE + ".*"
                rotated_candidates = sorted(glob.glob(base_pattern), key=os.path.getmtime)
                for p in rotated_candidates:
                    files_to_scan.append(p)
            files_to_scan.append(OUTFILE)

            # Streamed response (no Content-Length)
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/csv")
                self.send_header("Content-Disposition", f'attachment; filename="{os.path.basename(OUTFILE)}"')
                self.end_headers()

                header_sent = False
                total_rows = 0

                def open_file_for_read(path):
                    if path.endswith(".gz"):
                        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
                    else:
                        return open(path, "r", encoding="utf-8", errors="replace")

                for path in files_to_scan:
                    # prefer uncompressed if exists; else try .gz
                    if not os.path.exists(path):
                        if os.path.exists(path + ".gz"):
                            path = path + ".gz"
                        else:
                            continue
                    try:
                        fh = open_file_for_read(path)
                    except Exception:
                        logger.exception("Failed opening CSV file for scanning: %s", path)
                        continue

                    with fh:
                        first_line = fh.readline()
                        if not first_line:
                            continue
                        if not header_sent:
                            self.wfile.write(first_line.encode("utf-8"))
                            header_sent = True
                        for line in fh:
                            parts = line.split(",", 1)
                            if not parts:
                                continue
                            ts_str = parts[0].strip()
                            if not ts_str:
                                continue
                            try:
                                ts_iso = ts_str.replace(" ", "T")
                                if ts_iso.endswith("Z"):
                                    ts_iso = ts_iso[:-1] + "+00:00"
                                ts_dt = datetime.fromisoformat(ts_iso)
                                if ts_dt.tzinfo is None:
                                    ts_dt = ts_dt.replace(tzinfo=timezone.utc)
                                ts_dt = ts_dt.astimezone(timezone.utc)
                            except Exception:
                                continue
                            if start_dt and ts_dt < start_dt:
                                continue
                            if end_dt and ts_dt > end_dt:
                                continue
                            self.wfile.write(line.encode("utf-8"))
                            total_rows += 1
                logger.info("Served CSV range start=%s end=%s include_rotated=%s rows=%d to %s",
                            start_str, end_str, include_rotated, total_rows, self.client_address)
            except Exception:
                logger.exception("Failed to serve filtered CSV files: %s range %s - %s include_rotated=%s",
                                 OUTFILE, start_str, end_str, include_rotated)
                try:
                    if not self.wfile.closed:
                        self.send_response(500)
                        self.send_header("Content-Type", "text/plain")
                        self.end_headers()
                        self.wfile.write(b"internal server error\n")
                except Exception:
                    pass
            return

        # default 404
        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"not found\n")

    def log_message(self, format, *args):
        # Route http.server logs to our logger
        logger.debug("HTTP %s - %s", self.address_string(), format % args)


def start_http_server(port: int = METRICS_PORT):
    server = ThreadingHTTPServer(("0.0.0.0", port), MetricsHandler)
    t = threading.Thread(target=server.serve_forever, daemon=True, name="metrics-http-server")
    t.start()
    logger.info("Started HTTP metrics server on port %d (csv chunk_size=%d)", port, CHUNK_SIZE)
    return server


def main_loop():
    ensure_header(OUTFILE)
    try_load_config()
    start_http_server(METRICS_PORT)
    logger.info(
        "Starting main loop: INTERVAL=%s OUTFILE=%s NAMESPACE=%s POD_REGEX=%s LOG_LEVEL=%s METRICS_PORT=%s READY_THRESHOLD_SECONDS=%s CHUNK_SIZE=%d ROTATE_MAX_BYTES=%d ROTATE_COMPRESS=%s",
        INTERVAL,
        OUTFILE,
        NAMESPACE or "<all>",
        POD_REGEX or "<none>",
        LOG_LEVEL,
        METRICS_PORT,
        READY_THRESHOLD_SECONDS,
        CHUNK_SIZE,
        ROTATE_MAX_BYTES,
        ROTATE_COMPRESS,
    )
    while True:
        start = time.time()
        try:
            rows = fetch_pod_metrics()
            duration = time.time() - start
            rows_written = 0
            if rows:
                # rotate if file exceeded size BEFORE writing new rows
                try:
                    rotate_csv_if_needed()
                except Exception:
                    logger.exception("Error while attempting CSV rotation")

                ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                try:
                    ensure_header(OUTFILE)
                    with open(OUTFILE, "a", encoding="utf-8", newline="") as f:
                        writer = csv.writer(f)
                        for ns, pod, cpu_m, mem_Mi in rows:
                            writer.writerow([ts, ns, pod, f"{cpu_m:.3f}", f"{mem_Mi:.3f}"])
                            rows_written += 1
                    logger.info("Appended %d rows to %s", rows_written, OUTFILE)
                    logger.trace("Last timestamp written: %s", ts)
                except Exception:
                    logger.exception("Failed to append rows to CSV: %s", OUTFILE)
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
        "k8s-metrics-logger starting: INTERVAL=%s OUTFILE=%s NAMESPACE=%s POD_REGEX=%s TRY_INCLUSTER_FIRST=%s LOG_LEVEL=%s METRICS_PORT=%s READY_THRESHOLD_SECONDS=%s CHUNK_SIZE=%d ROTATE_MAX_BYTES=%d ROTATE_MAX_BACKUPS=%d ROTATE_COMPRESS=%s",
        INTERVAL,
        OUTFILE,
        NAMESPACE or "<all>",
        POD_REGEX or "<none>",
        TRY_INCLUSTER_FIRST,
        LOG_LEVEL,
        METRICS_PORT,
        READY_THRESHOLD_SECONDS,
        CHUNK_SIZE,
        ROTATE_MAX_BYTES,
        ROTATE_MAX_BACKUPS,
        ROTATE_COMPRESS,
    )
    main_loop()
