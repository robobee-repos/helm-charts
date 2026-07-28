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
HAPROXY_PID_FILE="${HAPROXY_PID_FILE:-/var/run/haproxy.pid}"
# consul-template uses CONSUL_HTTP_ADDR env var normally, but we keep CONSUL_ARGS for legacy
CONSUL_HTTP_ADDR="${CONSUL_HTTP}"

# Build consul-template args
CONSUL_ARGS="-consul-addr=${CONSUL_HTTP}"
if [ -n "${CONSUL_TOKEN}" ]; then
  # export token so consul-template or hooks can read from env if needed
  export CONSUL_TOKEN
  CONSUL_ARGS="${CONSUL_ARGS} -consul-token=${CONSUL_TOKEN}"
  debug "Using CONSUL_TOKEN from environment"
fi

# Ensure template exists
if [ ! -f "${TEMPLATE_PATH}" ]; then
  log "ERROR: template not found at ${TEMPLATE_PATH}"
  exit 1
fi

chmod +x "${RELOAD_CMD}"
log "Wrote reload helper at ${RELOAD_CMD}"

log "Rendering template once: ${TEMPLATE_PATH} -> ${OUTPUT_CFG}"
debug "Running: consul-template ${CONSUL_ARGS} -template \"${TEMPLATE_PATH}:${OUTPUT_CFG}:echo rendered\" -once ${CT_OPTS}"
consul-template ${CONSUL_ARGS} -template "${TEMPLATE_PATH}:${OUTPUT_CFG}:echo rendered" -once ${CT_OPTS}

# Validate generated config before starting haproxy
log "Validating HAProxy config: ${OUTPUT_CFG}"
debug "Generated HAProxy config: $(cat "${OUTPUT_CFG}" 2>/dev/null || true)"
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

# Start haproxy master-worker (initial start)
log "Starting haproxy master-worker with config ${OUTPUT_CFG}"
# Start detached so this script can continue managing both processes; the master will write the PID file.
nohup haproxy -f "${OUTPUT_CFG}" -p "${HAPROXY_PID_FILE}" -W >/dev/null 2>&1 &
# try to read pid file (give it a short moment)
sleep 0.2
if [ -f "${HAPROXY_PID_FILE}" ]; then
  HAPROXY_PID=$(cat "${HAPROXY_PID_FILE}" 2>/dev/null || true)
  debug "haproxy pid from pidfile=${HAPROXY_PID}"
else
  # fallback to $! (pid of last backgrounded nohup wrapper) though real master pid should be in pidfile
  HAPROXY_PID=$!
  debug "pidfile not found; using background PID=${HAPROXY_PID}"
fi

# Function to cleanup children on exit
cleanup() {
  log "Shutting down (trap triggered)"
  # stop consul-template first so no new reloads occur
  if [ -n "${CT_PID:-}" ] && kill -0 "${CT_PID}" 2>/dev/null; then
    log "Stopping consul-template (pid=${CT_PID})"
    kill -TERM "${CT_PID}" 2>/dev/null || true
    # give it a moment
    wait "${CT_PID}" 2>/dev/null || true
  fi

  # request HAProxy master to shut down gracefully
  if [ -f "${HAPROXY_PID_FILE}" ]; then
    PID=$(cat "${HAPROXY_PID_FILE}" 2>/dev/null || true)
    if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
      log "Stopping haproxy master (pid=${PID})"
      # send TERM to tell master to stop workers and exit
      kill -TERM "${PID}" 2>/dev/null || true
      # wait briefly
      sleep 1
    fi
  else
    if [ -n "${HAPROXY_PID:-}" ] && kill -0 "${HAPROXY_PID}" 2>/dev/null; then
      log "Stopping haproxy (pid=${HAPROXY_PID})"
      kill -TERM "${HAPROXY_PID}" 2>/dev/null || true
      sleep 1
    fi
  fi
}

trap 'cleanup; exit 0' SIGTERM SIGINT

# Monitor both processes. If consul-template dies, stop haproxy and exit non-zero.
while true; do
  # wait for any child
  wait -n || true
  # Re-evaluate statuses
  CT_ALIVE=0
  HAPROXY_ALIVE=0

  if [ -n "${CT_PID:-}" ] && kill -0 "${CT_PID}" 2>/dev/null; then CT_ALIVE=1; fi

  # Prefer reading pidfile for the actual master pid
  if [ -f "${HAPROXY_PID_FILE}" ]; then
    PID_READ=$(cat "${HAPROXY_PID_FILE}" 2>/dev/null || true)
    if [ -n "${PID_READ}" ] && kill -0 "${PID_READ}" 2>/dev/null; then
      HAPROXY_ALIVE=1
      HAPROXY_PID="${PID_READ}"
    fi
  else
    if [ -n "${HAPROXY_PID:-}" ] && kill -0 "${HAPROXY_PID}" 2>/dev/null; then
      HAPROXY_ALIVE=1
    fi
  fi

  if [ "${CT_ALIVE}" -eq 0 ] && [ "${HAPROXY_ALIVE}" -eq 0 ]; then
    log "Both consul-template and haproxy are stopped; exiting"
    exit 0
  fi

  if [ "${CT_ALIVE}" -eq 0 ]; then
    log "consul-template exited unexpectedly; stopping haproxy and exiting with error"
    cleanup
    exit 3
  fi

  if [ "${HAPROXY_ALIVE}" -eq 0 ]; then
    log "haproxy master exited; stopping consul-template and exiting (haproxy failure)"
    if [ -n "${CT_PID:-}" ] && kill -0 "${CT_PID}" 2>/dev/null; then
      kill -TERM "${CT_PID}" 2>/dev/null || true
      wait "${CT_PID}" 2>/dev/null || true
    fi
    exit 2
  fi

  # otherwise loop
  sleep 1
done
