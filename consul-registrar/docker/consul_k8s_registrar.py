#!/usr/bin/env python3
"""
consul_k8s_registrar.py

Watches Kubernetes Services (by label selector) and registers/deregisters
a Consul service based on a Service annotation. Includes debugging/logging,
a simple /healthz endpoint, retries, and dry-run mode.

Env vars:
  WATCH_NAMESPACE         (default: "")  -- namespace to watch, empty = all
  LABEL_SELECTOR          (default: "haproxy-enabled=true")
  ANNOTATION_KEY_BACKEND  (default: "haproxy.example.com/backend")  # value "ip" or "ip:port"
  ANNOTATION_KEY_NAME     (default: "haproxy.example.com/name")  # value "ldap"
  CONSUL_HTTP             (default: "http://127.0.0.1:8500")
  CONSUL_TOKEN            (optional) -- Consul ACL token
  SERVICE_NAME_PREFIX     (default: "haproxy-") -- used to build unique Consul ID
  SLEEP                   (default: 1) -- backoff on error
  LOG_LEVEL               (default: "INFO") -- DEBUG|INFO|WARNING|ERROR
  DRY_RUN                 (default: "false") -- if true, don't call Consul
  HEALTH_PORT             (default: 8080) -- port for /healthz
"""

import os
import time
import json
import logging
import threading
import requests
import re

from http.server import BaseHTTPRequestHandler, HTTPServer
from kubernetes import client, config, watch

# --- Configuration from environment ---
WATCH_NAMESPACE = os.getenv("WATCH_NAMESPACE", "")
LABEL_SELECTOR = os.getenv("LABEL_SELECTOR", "haproxy-enabled=true")
ANNOTATION_KEY_BACKEND = os.getenv("ANNOTATION_KEY_BACKEND", "haproxy.example.com/backend")
ANNOTATION_KEY_NAME = os.getenv("ANNOTATION_KEY_NAME", "haproxy.example.com/display-name")
CONSUL_HTTP = os.getenv("CONSUL_HTTP", "http://127.0.0.1:8500")
CONSUL_TOKEN = os.getenv("CONSUL_TOKEN", "")
SERVICE_NAME_PREFIX = os.getenv("SERVICE_NAME_PREFIX", "haproxy-")
SLEEP = float(os.getenv("SLEEP", "1"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
DRY_RUN = os.getenv("DRY_RUN", "false").lower() in ("1", "true", "yes")
HEALTH_PORT = int(os.getenv("HEALTH_PORT", "8080"))
RETRY_ATTEMPTS = int(os.getenv("RETRY_ATTEMPTS", "3"))
RETRY_BACKOFF = float(os.getenv("RETRY_BACKOFF", "0.5"))  # seconds

# --- Logging setup ---
logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO),
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("consul-registrar")

# --- HTTP session for Consul with optional token header ---
session = requests.Session()
session.headers.update({"Content-Type": "application/json"})
if CONSUL_TOKEN:
    session.headers.update({"X-Consul-Token": CONSUL_TOKEN})

# --- Health HTTP server (simple) ---
class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/health", "/ready"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    # avoid noisy logging from BaseHTTPRequestHandler
    def log_message(self, format, *args):
        log.debug("health-req: " + format % args)

def start_health_server(port):
    server = HTTPServer(("0.0.0.0", port), HealthHandler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    log.info("Health server listening on port %d", port)
    return server

# --- Helpers for Consul interaction with retries ---
def consul_put(path, data=None, attempts=RETRY_ATTEMPTS):
    url = CONSUL_HTTP.rstrip("/") + path
    body = json.dumps(data) if data is not None else None
    for attempt in range(1, attempts + 1):
        try:
            log.debug("Consul PUT %s (attempt %d) body=%s", url, attempt, body)
            r = session.put(url, data=body, timeout=5)
            r.raise_for_status()
            log.debug("Consul PUT succeeded: %s %s", url, r.status_code)
            return r
        except Exception as e:
            log.warning("Consul PUT failed (%s): %s", url, e)
            if attempt < attempts:
                time.sleep(RETRY_BACKOFF * attempt)
            else:
                raise

def consul_register(id, name, addr, port, tags=None):
    payload = {
        "ID": id,
        "Name": name,
        "Address": addr,
        "Port": int(port),
        "Tags": tags or []
    }
    if DRY_RUN:
        log.info("DRY-RUN register id=%s name=%s addr=%s port=%s tags=%s", id, name, addr, port, tags)
        return
    log.info("Registering Consul service id=%s name=%s -> %s:%s", id, name, addr, port)
    consul_put("/v1/agent/service/register", payload)

def consul_deregister(id):
    url = "/v1/agent/service/deregister/{}".format(id)
    if DRY_RUN:
        log.info("DRY-RUN deregister id=%s", id)
        return
    log.info("Deregistering Consul service id=%s", id)
    consul_put(url, data=None)

# --- Utility parsing / id helpers ---
def sanitize_consul_name(s: str) -> str:
    # Lowercase, replace invalid chars with hyphen, collapse multiple hyphens
    s = (s or "").strip().lower()
    s = re.sub(r'[^a-z0-9\-]', '-', s)
    s = re.sub(r'-{2,}', '-', s)
    s = s.strip('-')
    return s or "service"

def get_consul_name_and_meta(svc):
    """
    Prefer an annotation 'haproxy.example.com/display-name' for human label,
    otherwise use the k8s service name. Return (name_for_consul, meta_dict).
    """
    anns = svc.metadata.annotations or {}
    display = anns.get(ANNOTATION_KEY_NAME)
    # fallback to the k8s service name (without namespace)
    base_name = svc.metadata.name
    # you may optionally include namespace in the name if you need global uniqueness:
    # base_name = f"{svc.metadata.namespace}-{svc.metadata.name}"
    name = sanitize_consul_name(display if display else base_name)
    meta = {}
    if display:
        meta["display_name"] = display
    return name, meta

def parse_addrport(v):
    if not v:
        return None, None
    v = v.strip()
    if ":" in v:
        ip, port = v.rsplit(":", 1)
    else:
        ip, port = v, "80"
    ip = ip.strip()
    port = port.strip()
    if not ip:
        return None, None
    return ip, port

def svc_id(ns, name):
    # use prefix + namespace + name to ensure id uniqueness across namespaces
    safe_ns = ns.replace("/", "_")
    safe_name = name.replace("/", "_")
    return f"{SERVICE_NAME_PREFIX}{safe_ns}-{safe_name}"

# --- Helpers to handle both dict and model objects ---
def _is_dict(o):
    return isinstance(o, dict)

def svc_namespace(svc):
    if _is_dict(svc):
        return svc.get("metadata", {}).get("namespace")
    return getattr(svc.metadata, "namespace", None)

def svc_name_field(svc):
    if _is_dict(svc):
        return svc.get("metadata", {}).get("name")
    return getattr(svc.metadata, "name", None)

def svc_annotations(svc):
    if _is_dict(svc):
        return svc.get("metadata", {}).get("annotations") or {}
    anns = getattr(svc.metadata, "annotations", None)
    return anns or {}

def svc_resource_version(svc):
    if _is_dict(svc):
        return svc.get("metadata", {}).get("resourceVersion")
    return getattr(svc.metadata, "resource_version", None)

# --- Main watch loop ---
def run_loop():
    # load kube config (in-cluster or kubeconfig)
    try:
        config.load_incluster_config()
        log.info("Loaded in-cluster Kubernetes configuration")
    except Exception:
        config.load_kube_config()
        log.info("Loaded local kubeconfig")

    v1 = client.CoreV1Api()
    w = watch.Watch()

    list_func = v1.list_service_for_all_namespaces if not WATCH_NAMESPACE else lambda **kwargs: v1.list_namespaced_service(WATCH_NAMESPACE, **kwargs)
    log.info("Starting watch; namespace=%s selector=%s annotation=%s", WATCH_NAMESPACE or "ALL", LABEL_SELECTOR, ANNOTATION_KEY_BACKEND)

    # Use an infinite stream (timeout_seconds=0) and handle transient exceptions cleanly
    while True:
        try:
            stream = w.stream(list_func, label_selector=LABEL_SELECTOR, timeout_seconds=0)
            for ev in stream:
                typ = ev.get("type")
                svc = ev.get("object")
                if svc is None:
                    log.debug("Received empty event object")
                    continue

                # normalize metadata via accessors
                ns = svc_namespace(svc)
                name = svc_name_field(svc)
                fullname = f"{ns}/{name}"
                rv = svc_resource_version(svc)
                anns = svc_annotations(svc)
                ann = anns.get(ANNOTATION_KEY_BACKEND)
                log.debug("Event %s for %s (rv=%s) annotations=%s", typ, fullname, rv, {ANNOTATION_KEY_BACKEND: ann})

                id = svc_id(ns, name)
                try:
                    if typ in ("ADDED", "MODIFIED"):
                        if ann:
                            addr, port = parse_addrport(ann)
                            if not addr:
                                log.warning("Annotation present but parse failed for %s: %s", fullname, ann)
                                continue
                            # register/update
                            try:
                                consul_name, consul_meta = get_consul_name_and_meta(svc)
                                consul_register(id=id, name=consul_name, addr=addr, port=port, tags=["k8s"], meta=consul_meta)
                            except Exception as e:
                                log.error("Failed to register %s -> %s:%s: %s", fullname, addr, port, e)
                        else:
                            # annotation removed -> deregister
                            try:
                                consul_deregister(id)
                            except Exception as e:
                                log.error("Failed to deregister %s: %s", fullname, e)
                    elif typ == "DELETED":
                        try:
                            consul_deregister(id)
                        except Exception as e:
                            log.error("Failed to deregister on delete %s: %s", fullname, e)
                    else:
                        log.debug("Unhandled event type %s for %s", typ, fullname)
                except Exception as e:
                    log.exception("Unhandled exception processing %s event for %s: %s", typ, fullname, e)
                    time.sleep(SLEEP)
        except Exception as e:
            log.exception("Watch stream error, restarting watch loop: %s", e)
            time.sleep(max(1.0, SLEEP))

# --- Entrypoint ---
def main():
    log.info("Starting consul-registrar (DRY_RUN=%s LOG_LEVEL=%s)", DRY_RUN, LOG_LEVEL)
    health = start_health_server(HEALTH_PORT)
    try:
        run_loop()
    except KeyboardInterrupt:
        log.info("Interrupted, exiting")
    finally:
        try:
            health.shutdown()
        except Exception:
            pass
        log.info("Stopped")

if __name__ == "__main__":
    main()
