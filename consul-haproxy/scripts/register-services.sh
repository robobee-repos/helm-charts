#!/bin/sh
set -eu
set -x

# register-services.sh
# Wait for Consul, resolve container IPs for compose service names, and register two services.

CONSUL=${CONSUL:-http://consul:8500}
SERVICES_WAIT_TIMEOUT=${SERVICES_WAIT_TIMEOUT:-30}  # seconds to wait for DNS resolution per service

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# wait for consul leader
log "Waiting for Consul to be available at ${CONSUL}..."
until curl -sSf "${CONSUL}/v1/status/leader" >/dev/null 2>&1; do
  log "Consul not ready yet..."
  sleep 1
done
log "Consul is ready."

# Resolve a hostname to an IP using several fallbacks.
# Returns IP on stdout and exit 0; otherwise exit 1.
resolve_ip_once() {
  name="$1"

  # 1) getent ahosts (glibc) -> first column
  if command -v getent >/dev/null 2>&1; then
    ip=$(getent ahosts "$name" 2>/dev/null | awk '{print $1; exit}' || true)
    [ -n "${ip}" ] && { printf '%s' "$ip"; return 0; }
  fi

  # 2) getent hosts
  if command -v getent >/dev/null 2>&1; then
    ip=$(getent hosts "$name" 2>/dev/null | awk '{print $1; exit}' || true)
    [ -n "${ip}" ] && { printf '%s' "$ip"; return 0; }
  fi

  # 3) /etc/hosts lookup
  if [ -f /etc/hosts ]; then
    ip=$(awk -v host="$name" '$0 !~ /^#/ { for(i=2;i<=NF;i++) if($i==host){print $1; exit}}' /etc/hosts || true)
    [ -n "${ip}" ] && { printf '%s' "$ip"; return 0; }
  fi

  # 4) ping and parse output (busybox / iputils variants)
  if command -v ping >/dev/null 2>&1; then
    if ping -c1 -W1 "$name" >/dev/null 2>&1; then
      # ping output examples:
      #   PING ldap-service (172.18.0.3): 56 data bytes
      #   PING 172.18.0.3 (172.18.0.3): 56 data bytes
      out=$(ping -c1 -W1 "$name" 2>/dev/null || true)
      ip=$(printf '%s' "$out" | sed -n 's/.*(\([0-9\.]\+\)).*/\1/p' | head -n1 || true)
      if [ -n "${ip}" ]; then
        printf '%s' "$ip"; return 0
      fi
    fi
  fi

  # 5) nslookup
  if command -v nslookup >/dev/null 2>&1; then
    ip=$(nslookup "$name" 2>/dev/null | awk -F': ' '/^Address: /{print $2; exit}' || true)
    [ -n "${ip}" ] && { printf '%s' "$ip"; return 0; }
  fi

  # 6) dig
  if command -v dig >/dev/null 2>&1; then
    ip=$(dig +short "$name" A | head -n1 || true)
    [ -n "${ip}" ] && { printf '%s' "$ip"; return 0; }
  fi

  return 1
}

# Resolve with retries up to timeout seconds
resolve_with_retry() {
  name="$1"
  timeout=${2:-${SERVICES_WAIT_TIMEOUT}}
  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if ip=$(resolve_ip_once "$name"); then
      printf '%s' "$ip"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# Resolve services on the docker-compose network
LDAP_NAME="ldap-service"
API_NAME="api-service"

log "Resolving ${LDAP_NAME}..."
LDAP_IP=$(resolve_with_retry "${LDAP_NAME}" 30) || {
  log "ERROR: failed to resolve ${LDAP_NAME} to an IP within timeout"
  exit 1
}
log "Resolved ${LDAP_NAME} -> ${LDAP_IP}"

log "Resolving ${API_NAME}..."
API_IP=$(resolve_with_retry "${API_NAME}" 30) || {
  log "ERROR: failed to resolve ${API_NAME} to an IP within timeout"
  exit 1
}
log "Resolved ${API_NAME} -> ${API_IP}"

# helper to register service to Consul agent
register_service() {
  name="$1"
  id="$2"
  addr="$3"
  port="$4"
  vhost="$5"
  display="$6"

cat <<JSON | curl -sS -X PUT -d @- "${CONSUL}/v1/agent/service/register" -H "Content-Type: application/json"
{
  "Name": "${name}",
  "ID": "${id}",
  "Address": "${addr}",
  "Port": ${port},
  "Tags": ["k8s"],
  "Meta": {
    "display_name": "${display}",
    "vhost": "${vhost}"
  }
}
JSON
  log "Registered ${name} (id=${id}) -> ${addr}:${port} (vhost=${vhost})"
}

# register ldap
register_service "ldap" "ldap-1" "${LDAP_IP}" 80 "ldap.example.local" "LDAP Service"

# register api
register_service "api" "api-1" "${API_IP}" 80 "api.example.local" "API Service"

log "Service registration complete."
