#!/usr/bin/env bash
# docker-entrypoint.sh
# Entrypoint for the consul-k8s-registrar container.
# - optional wait for Consul to be ready
# - optional debug output
# - forwards signals to the child process and exits with child's code

set -o errexit
set -o nounset
set -o pipefail

# Configuration (can be overridden by env)
CONSUL_HTTP="${CONSUL_HTTP:-http://127.0.0.1:8500}"
WAIT_FOR_CONSUL="${WAIT_FOR_CONSUL:-true}"       # true/false
WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"               # seconds total
WAIT_INTERVAL="${WAIT_INTERVAL:-1}"              # seconds between attempts
LOG_LEVEL="${LOG_LEVEL:-INFO}"                   # DEBUG/INFO/...
DRY_RUN="${DRY_RUN:-false}"

# logging helpers
log() { printf '%s %s\n' "$(date -Is)" "$*"; }
debug() { [[ "${LOG_LEVEL}" == "DEBUG" ]] && log "DEBUG: $*"; }

# wait_for_consul: poll the Consul HTTP API until available or timeout
wait_for_consul() {
  if [[ "${WAIT_FOR_CONSUL}" != "true" ]]; then
    debug "Skipping Consul wait (WAIT_FOR_CONSUL=${WAIT_FOR_CONSUL})"
    return 0
  fi

  log "Waiting for Consul at ${CONSUL_HTTP} (timeout ${WAIT_TIMEOUT}s)..."
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while true; do
    # try leader endpoint first, fallback to agent self
    if curl -s --max-time 2 "${CONSUL_HTTP%/}/v1/status/leader" >/dev/null 2>&1; then
      log "Consul reachable (status/leader)"
      return 0
    fi
    if curl -s --max-time 2 "${CONSUL_HTTP%/}/v1/agent/self" >/dev/null 2>&1; then
      log "Consul reachable (agent/self)"
      return 0
    fi

    if [[ $(date +%s) -ge ${deadline} ]]; then
      log "Timed out waiting for Consul at ${CONSUL_HTTP} after ${WAIT_TIMEOUT}s"
      return 1
    fi
    sleep "${WAIT_INTERVAL}"
  done
}

# If the user passed a single argument that is a flag-style (e.g. --help),
# or explicitly specified the script to run, we still exec "$@" below.
# Print environment useful for debugging when LOG_LEVEL=DEBUG
dump_env_if_debug() {
  if [[ "${LOG_LEVEL}" == "DEBUG" ]]; then
    log "Environment (selected): CONSUL_HTTP=${CONSUL_HTTP}, WAIT_FOR_CONSUL=${WAIT_FOR_CONSUL}, DRY_RUN=${DRY_RUN}, user-id=`whois`"
  fi
}

# Forward signals to the child process
child_pid=0
_forward_signal() {
  sig="$1"
  if [[ "${child_pid}" -ne 0 ]]; then
    log "Forwarding signal ${sig} to child ${child_pid}"
    kill -s "${sig}" "${child_pid}" 2>/dev/null || true
  fi
}

# trap signals
trap 'child_pid=${child_pid} && _forward_signal TERM' TERM
trap 'child_pid=${child_pid} && _forward_signal INT' INT
trap 'child_pid=${child_pid} && _forward_signal QUIT' QUIT
trap 'child_pid=${child_pid} && _forward_signal HUP' HUP

main() {
  dump_env_if_debug

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY_RUN=true: will not call Consul; printing planned actions only."
  fi

  if ! wait_for_consul; then
    log "Consul not available. Exiting with non-zero status."
    exit 2
  fi

  # Exec the provided command as the container's main process.
  # If no command provided, default to running the Python script path that the image expects.
  if [[ $# -eq 0 ]]; then
    # default fallback: run the app script if present
    if [[ -x /app/consul_k8s_registrar.py || -f /app/consul_k8s_registrar.py ]]; then
      set -- python /app/consul_k8s_registrar.py
    else
      log "No command specified and /app/consul_k8s_registrar.py not found. Exiting."
      exit 3
    fi
  fi

  log "Starting: $*"
  # start the child process in background so we can trap and forward signals
  "$@" &
  child_pid=$!
  debug "Spawned child pid=${child_pid}"

  # wait for the child and reap it
  wait "${child_pid}"
  exit_code=$?
  log "Child ${child_pid} exited with code ${exit_code}"
  exit "${exit_code}"
}

main "$@"
