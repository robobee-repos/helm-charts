#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# logging helpers
log() { printf '%s %s\n' "$(date -Is)" "$*"; }
debug() { [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]] && log "DEBUG: $*"; }

# enable xtrace in DEBUG mode
if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
  set -x
fi

# Env vars (with sensible defaults)
CONSUL_HTTP="${CONSUL_HTTP:-http://127.0.0.1:8500}"
CONSUL_TOKEN="${CONSUL_TOKEN:-}"
TEMPLATE_PATH="${TEMPLATE_PATH:-/templates/haproxy.ctmpl}"
OUTPUT_CFG="${OUTPUT_CFG:-/etc/haproxy/haproxy.cfg}"
RELOAD_CMD="${RELOAD_CMD:-/usr/local/bin/haproxy_reload.sh}"
CT_OPTS="${CT_OPTS:-}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"                   # DEBUG/INFO/...

# Build consul-template args
CONSUL_ARGS="-consul-addr=${CONSUL_HTTP}"
if [ -n "${CONSUL_TOKEN}" ]; then
  # Export token so consul-template can also read from env if needed
  export CONSUL_TOKEN
  CONSUL_ARGS="${CONSUL_ARGS} -consul-token=${CONSUL_TOKEN}"
  debug "Using CONSUL_TOKEN from environment"
fi

# Ensure template exists
if [ ! -f "${TEMPLATE_PATH}" ]; then
  log "ERROR: template not found at ${TEMPLATE_PATH}"
  exit 1
fi

log "Rendering template once: ${TEMPLATE_PATH} -> ${OUTPUT_CFG}"
debug "Running: consul-template ${CONSUL_ARGS} -template \"${TEMPLATE_PATH}:${OUTPUT_CFG}:echo rendered\" -once ${CT_OPTS}"
consul-template ${CONSUL_ARGS} -template "${TEMPLATE_PATH}:${OUTPUT_CFG}:echo rendered" -once ${CT_OPTS}

# Validate generated config before starting haproxy
log "Validating HAProxy config: ${OUTPUT_CFG}"
if ! haproxy -c -f "${OUTPUT_CFG}"; then
  log "ERROR: haproxy config validation failed, aborting"
  exit 2
fi

# Start consul-template watcher (runs hooks on change)
log "Starting consul-template watcher"
debug "Running consul-template in watch mode with template hook: ${RELOAD_CMD}"
consul-template ${CONSUL_ARGS} -template "${TEMPLATE_PATH}:${OUTPUT_CFG}:${RELOAD_CMD}" ${CT_OPTS} &
CT_PID=$!
debug "consul-template pid=${CT_PID}"

# Function to cleanup children on exit
cleanup() {
  log "Shutting down (trap triggered)"
  # send TERM to consul-template
  if [ -n "${CT_PID:-}" ] && kill -0 "${CT_PID}" 2>/dev/null; then
    log "Stopping consul-template (pid=${CT_PID})"
    kill -TERM "${CT_PID}" 2>/dev/null || true
  fi
  # send TERM to haproxy if running
  if [ -n "${HAPROXY_PID:-}" ] && kill -0 "${HAPROXY_PID}" 2>/dev/null; then
    log "Stopping haproxy (pid=${HAPROXY_PID})"
    kill -TERM "${HAPROXY_PID}" 2>/dev/null || true
  fi
}

trap 'cleanup; exit 0' SIGTERM SIGINT

# Start haproxy in foreground (but here we run in background so we can manage both)
log "Starting haproxy with config ${OUTPUT_CFG}"
haproxy -f "${OUTPUT_CFG}" -p /var/run/haproxy.pid -db &
HAPROXY_PID=$!
debug "haproxy pid=${HAPROXY_PID}"

# Wait for any process to exit. If haproxy exits, stop consul-template and exit with haproxy's code.
# If consul-template exits (unexpected), stop haproxy and exit non-zero.
while true; do
  wait -n
  EXIT_STATUS=$?
  # Check which PIDs are still alive
  HAPROXY_ALIVE=0
  CT_ALIVE=0
  if [ -n "${HAPROXY_PID:-}" ] && kill -0 "${HAPROXY_PID}" 2>/dev/null; then HAPROXY_ALIVE=1; fi
  if [ -n "${CT_PID:-}" ] && kill -0 "${CT_PID}" 2>/dev/null; then CT_ALIVE=1; fi

  if [ "${HAPROXY_ALIVE}" -eq 0 ] && [ "${CT_ALIVE}" -eq 0 ]; then
    log "Both haproxy and consul-template have exited; returning status ${EXIT_STATUS}"
    exit "${EXIT_STATUS}"
  fi

  # If haproxy exited, stop consul-template and exit with haproxy's status
  if [ "${HAPROXY_ALIVE}" -eq 0 ]; then
    log "haproxy exited; stopping consul-template (pid=${CT_PID:-unknown})"
    if [ -n "${CT_PID:-}" ] && kill -0 "${CT_PID}" 2>/dev/null; then
      kill -TERM "${CT_PID}" 2>/dev/null || true
      wait "${CT_PID}" 2>/dev/null || true
    fi
    exit "${EXIT_STATUS}"
  fi

  # If consul-template exited, stop haproxy and exit non-zero (consul-template should be long-running)
  if [ "${CT_ALIVE}" -eq 0 ]; then
    log "consul-template exited unexpectedly; stopping haproxy (pid=${HAPROXY_PID:-unknown})"
    if [ -n "${HAPROXY_PID:-}" ] && kill -0 "${HAPROXY_PID}" 2>/dev/null; then
      kill -TERM "${HAPROXY_PID}" 2>/dev/null || true
      wait "${HAPROXY_PID}" 2>/dev/null || true
    fi
    exit 3
  fi

  # otherwise loop and wait again
done
