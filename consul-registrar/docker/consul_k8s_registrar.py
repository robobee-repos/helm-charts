#!/usr/bin/env python3
"""
consul_k8s_registrar.py (Gateway-based)

Watches Gateway resources (gateway.networking.k8s.io/v1) and registers/deregisters
a Consul service per Gateway listener (when hostname is present). Behavior mostly
mirrors the original Service-based registrar but uses Gateway.spec.listeners and
Gateway.status.addresses for address/port/vhost information.

Env vars (existing plus):
  ANNOTATION_KEY_VHOST    (default: "haproxy.example.com/vhost")  # optional vhost annotation
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
from kubernetes.client import CustomObjectsApi

# --- Configuration from environment ---
WATCH_NAMESPACE = os.getenv("WATCH_NAMESPACE", "")
LABEL_SELECTOR = os.getenv("LABEL_SELECTOR", "")  # not used for Gateways but kept for parity
ANNOTATION_KEY_BACKEND = os.getenv("ANNOTATION_KEY_BACKEND", "haproxy.example.com/backend")  # (not used for Gateway)
ANNOTATION_KEY_NAME = os.getenv("ANNOTATION_KEY_NAME", "haproxy.example.com/display-name")
ANNOTATION_KEY_VHOST = os.getenv("ANNOTATION_KEY_VHOST", "haproxy.example.com/vhost")
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
log = logging.getLogger("consul-registrar-gateway")

# --- HTTP session for Consul with optional token header ---
session = requests.Session()
session.headers.update({"Content-Type": "application/json"})
if CONSUL_TOKEN:
    session.headers.update({"X-Consul-Token": CONSUL_TOKEN})

# --- In-memory tracking of registrations: map key -> consul_id
# key = "<namespace>/<gateway-name>:<listener-name-or-host>"
registered_ids = {}

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

    def log_message(self, format, *args):
        log.debug("health-req: " + format % args)

def start_health_server(port):
    server = HTTPServer(("0.0.0.0", port), HealthHandler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    log.info("Health server listening on port %d", port)
    return server

# --- Consul helpers with retries ---
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

def consul_register(id, name, addr, port, tags=None, meta=None):
    payload = {
        "ID": id,
        "Name": name,
        "Address": addr,
        "Port": int(port),
        "Tags": tags or []
    }
    if meta:
        payload["Meta"] = meta
    if DRY_RUN:
        log.info("DRY-RUN register id=%s name=%s addr=%s port=%s tags=%s meta=%s",
                 id, name, addr, port, tags, meta)
        return
    log.info("Registering Consul service id=%s name=%s -> %s:%s (meta=%s tags=%s)", id, name, addr, port, meta, tags)
    consul_put("/v1/agent/service/register", payload)

def consul_deregister(id):
    url = "/v1/agent/service/deregister/{}".format(id)
    if DRY_RUN:
        log.info("DRY-RUN deregister id=%s", id)
        return
    log.info("Deregistering Consul service id=%s", id)
    consul_put(url, data=None)

# --- Utility helpers ---
def sanitize_consul_name(s: str) -> str:
    s = (s or "").strip().lower()
    s = re.sub(r'[^a-z0-9\-]', '-', s)
    s = re.sub(r'-{2,}', '-', s)
    s = s.strip('-')
    return s or "service"

def make_registration_name(display_annotation, fallback_name):
    # choose display annotation if present otherwise fallback_name; sanitize
    base = display_annotation if display_annotation else fallback_name
    return sanitize_consul_name(base)

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

def build_consul_id(ns, gwname, listener_ident):
    # ensure uniqueness per namespace/gateway/listener
    safe_ns = (ns or "").replace("/", "_")
    safe_gw = (gwname or "").replace("/", "_")
    safe_listener = (listener_ident or "").replace("/", "_").replace(":", "_")
    return f"{SERVICE_NAME_PREFIX}{safe_ns}-{safe_gw}-{safe_listener}"

# --- Helpers to read metadata from dict-model custom object ---
def meta_namespace(obj):
    return obj.get("metadata", {}).get("namespace")

def meta_name(obj):
    return obj.get("metadata", {}).get("name")

def meta_annotations(obj):
    return obj.get("metadata", {}).get("annotations") or {}

def status_addresses(obj):
    # returns a list of address values or empty list
    status = obj.get("status") or {}
    addrs = status.get("addresses") or []
    out = []
    for a in addrs:
        if not a:
            continue
        v = a.get("value") or a.get("ip") or a.get("hostname")
        if v:
            out.append(v)
    return out

# --- Main watch loop for Gateways ---
def run_loop():
    # load kube config (in-cluster or kubeconfig)
    try:
        config.load_incluster_config()
        log.info("Loaded in-cluster Kubernetes configuration")
    except Exception:
        config.load_kube_config()
        log.info("Loaded local kubeconfig")

    custom = CustomObjectsApi()
    w = watch.Watch()

    group = "gateway.networking.k8s.io"
    version = "v1"
    plural = "gateways"

    # pick list function depending on namespace
    if not WATCH_NAMESPACE:
        list_func = lambda **kwargs: custom.list_cluster_custom_object(group=group, version=version, plural=plural, **kwargs)
        log.info("Watching Gateways cluster-wide")
    else:
        list_func = lambda **kwargs: custom.list_namespaced_custom_object(group=group, version=version, namespace=WATCH_NAMESPACE, plural=plural, **kwargs)
        log.info("Watching Gateways in namespace=%s", WATCH_NAMESPACE)

    while True:
        try:
            stream = w.stream(list_func, timeout_seconds=0)
            for ev in stream:
                typ = ev.get("type")
                gw = ev.get("object")
                if gw is None:
                    log.debug("Received empty event object")
                    continue

                ns = meta_namespace(gw) or ""
                name = meta_name(gw) or ""
                fullname = f"{ns}/{name}"
                anns = meta_annotations(gw)
                log.debug("Event %s for Gateway %s", typ, fullname)

                try:
                    # For ADDED/MODIFIED, register/update each listener that has hostname and address
                    if typ in ("ADDED", "MODIFIED"):
                        spec = gw.get("spec") or {}
                        listeners = spec.get("listeners") or []
                        # collect status addresses (may be node IPs / LB IPs)
                        addrs = status_addresses(gw)
                        # pick primary address if any
                        addr_from_status = addrs[0] if addrs else None

                        # build a set of current listener keys so we can cleanup removed listeners
                        current_listener_keys = set()

                        for listener in listeners:
                            # listener can be string-keyed dict
                            listener_name = listener.get("name") or listener.get("protocol") or ""
                            hostname = listener.get("hostname")  # may be None
                            port = listener.get("port") or 80

                            # produce a listener identifier used in ID and tracking
                            listener_ident = listener_name if listener_name else (hostname or str(port))

                            key = f"{fullname}:{listener_ident}"
                            current_listener_keys.add(key)

                            # decide address to register: prefer status.addresses value; if not present skip
                            reg_addr = addr_from_status
                            if not reg_addr:
                                # try annotations for an explicit backend address (ANNOTATION_KEY_BACKEND) on the gateway metadata
                                backend_ann = anns.get(ANNOTATION_KEY_BACKEND)
                                if backend_ann:
                                    reg_addr, reg_port = parse_addrport(backend_ann)
                                else:
                                    reg_addr = None
                                    reg_port = port
                            else:
                                reg_port = port

                            if not reg_addr:
                                log.info("Gateway %s listener %s has no Address to register (no status.addresses and no %s annotation); skipping", fullname, listener_ident, ANNOTATION_KEY_BACKEND)
                                # ensure any previous registration for this key is removed
                                prev_id = registered_ids.pop(key, None)
                                if prev_id:
                                    try:
                                        consul_deregister(prev_id)
                                    except Exception as e:
                                        log.error("Failed to deregister previous id=%s for %s: %s", prev_id, key, e)
                                continue

                            # determine consul service name & meta
                            # prefer annotation display name; if missing use gateway namespace/name as display_name
                            display_ann = anns.get(ANNOTATION_KEY_NAME)
                            if display_ann:
                                display_value = display_ann
                            else:
                                # use namespace/name as the display name when no annotation is present
                                display_value = f"{ns}/{name}"

                            # consul service name (sanitized)
                            consul_name = sanitize_consul_name(display_value)

                            # prepare meta (always include display_name per request)
                            meta = {"display_name": display_value}

                            # vhost: prefer hostname, else annotation ANNOTATION_KEY_VHOST if present
                            vhost_ann = anns.get(ANNOTATION_KEY_VHOST)
                            vhost_val = hostname or vhost_ann
                            if vhost_val:
                                meta["vhost"] = vhost_val

                            # tags: include k8s, gateway, and vhost=...
                            tags = ["k8s", "gateway"]
                            if vhost_val:
                                tags.append(f"vhost={vhost_val}")

                            # build unique id per listener
                            cid = build_consul_id(ns, name, listener_ident)

                            try:
                                consul_register(id=cid, name=consul_name, addr=reg_addr, port=reg_port, tags=tags, meta=meta)
                                registered_ids[key] = cid
                            except Exception as e:
                                log.error("Failed to register Gateway %s listener %s -> %s:%s: %s", fullname, listener_ident, reg_addr, reg_port, e)

                        # cleanup any registered listener IDs that are no longer present in the Gateway spec
                        to_remove = [k for k in registered_ids.keys() if k.startswith(fullname + ":") and k not in current_listener_keys]
                        for k in to_remove:
                            old_id = registered_ids.pop(k, None)
                            if old_id:
                                try:
                                    consul_deregister(old_id)
                                except Exception as e:
                                    log.error("Failed to deregister removed listener id=%s for %s: %s", old_id, k, e)

                    elif typ == "DELETED":
                        # deregister all listeners for this gateway
                        prefix = fullname + ":"
                        keys = [k for k in list(registered_ids.keys()) if k.startswith(prefix)]
                        for k in keys:
                            cid = registered_ids.pop(k, None)
                            if cid:
                                try:
                                    consul_deregister(cid)
                                except Exception as e:
                                    log.error("Failed to deregister on delete %s: %s", k, e)
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
    log.info("Starting consul-registrar-gateway (DRY_RUN=%s LOG_LEVEL=%s)", DRY_RUN, LOG_LEVEL)
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
