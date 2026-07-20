#!/usr/bin/env python3
# consul_k8s_registrar.py
import os, time, json, requests
from kubernetes import client, config, watch

NAMESPACE = os.getenv("WATCH_NAMESPACE", "")  # empty => all namespaces
LABEL_SELECTOR = os.getenv("LABEL_SELECTOR", "haproxy-enabled=true")
ANNOTATION_KEY = os.getenv("ANNOTATION_KEY", "haproxy.example.com/backend")
CONSUL_HTTP = os.getenv("CONSUL_HTTP", "http://127.0.0.1:8500")
SERVICE_NAME_PREFIX = os.getenv("SERVICE_NAME_PREFIX", "haproxy-")
SLEEP = 1

session = requests.Session()
session.headers.update({"Content-Type":"application/json"})

def consul_register(id, name, addr, port, tags=None):
    payload = {
        "ID": id,
        "Name": name,
        "Address": addr,
        "Port": int(port),
        "Tags": tags or []
    }
    url = f"{CONSUL_HTTP}/v1/agent/service/register"
    r = session.put(url, data=json.dumps(payload), timeout=5)
    r.raise_for_status()

def consul_deregister(id):
    url = f"{CONSUL_HTTP}/v1/agent/service/deregister/{id}"
    r = session.put(url, timeout=5)
    r.raise_for_status()

def parse_addrport(v):
    # accepts "ip" or "ip:port"
    if not v: return None, None
    if ":" in v:
        ip, port = v.rsplit(":", 1)
    else:
        ip, port = v, "80"
    return ip, port

def svc_id(ns, name):
    return f"{SERVICE_NAME_PREFIX}{ns}-{name}"

def main():
    try:
        config.load_incluster_config()
    except:
        config.load_kube_config()
    v1 = client.CoreV1Api()
    w = watch.Watch()
    stream = w.stream(v1.list_service_for_all_namespaces if not NAMESPACE else lambda **kwargs: v1.list_namespaced_service(NAMESPACE, **kwargs),
                      label_selector=LABEL_SELECTOR, timeout_seconds=0)
    for ev in stream:
        typ = ev["type"]
        svc = ev["object"]
        ns = svc.metadata.namespace
        name = svc.metadata.name
        anns = svc.metadata.annotations or {}
        ann = anns.get(ANNOTATION_KEY)
        id = svc_id(ns, name)
        try:
            if typ in ("ADDED", "MODIFIED"):
                if ann:
                    addr, port = parse_addrport(ann)
                    if addr:
                        consul_register(id=id, name="ldap", addr=addr, port=port, tags=["k8s"])
                else:
                    # annotation removed => deregister
                    consul_deregister(id)
            elif typ == "DELETED":
                consul_deregister(id)
        except Exception as e:
            print("error handling", ns, name, typ, e)
            time.sleep(SLEEP)

if __name__ == "__main__":
    main()
