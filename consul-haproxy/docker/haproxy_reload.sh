#!/bin/sh
set -o errexit
set -o nounset
set -o pipefail

# haproxy_reload.sh
# Usage: invoked by consul-template hook to atomically validate and reload HAProxy.
#
# Environment (optional):
#   OUTPUT_CFG         - path to the rendered haproxy config (default: /etc/haproxy/haproxy.cfg)
#   HAPROXY_PID_FILE   - path to pidfile (default: /var/run/haproxy.pid)
#   LOGFILE            - path to reload log (default: /var/log/haproxy_reload.log)
#   START_TIMEOUT      - seconds to wait for new pidfile to appear (default: 5)
#   LOCKDIR            - lockdir to serialize reloads (default: /var/run/haproxy-reload.lock)

OUTPUT_CFG="${OUTPUT_CFG:-/etc/haproxy/haproxy.cfg}"
HAPROXY_PID_FILE="${HAPROXY_PID_FILE:-/var/run/haproxy.pid}"
LOGFILE="${LOGFILE:-/var/log/haproxy_reload.log}"
START_TIMEOUT="${START_TIMEOUT:-5}"
LOCKDIR="${LOCKDIR:-/var/run/haproxy-reload.lock}"

log() {
  printf '%s %s\n' "$(date -Is)" "$*" >> "${LOGFILE}"
}

err() {
  printf '%s %s\n' "$(date -Is)" "ERROR: $*" >> "${LOGFILE}"
}

# enable xtrace in DEBUG mode
if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
  set -x
fi

# Acquire lock (mkdir-based). Wait up to 10s for lock to be available.
acquire_lock() {
  tries=0
  while ! mkdir "${LOCKDIR}" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 10 ]; then
      err "Could not acquire lock ${LOCKDIR} after $tries attempts"
      return 1
    fi
    sleep 1
  done
  # ensure lock removed at exit
  trap 'rm -rf "${LOCKDIR}"' EXIT INT TERM
  return 0
}

# Validate config
if [ ! -f "${OUTPUT_CFG}" ]; then
  err "Config file not found: ${OUTPUT_CFG}"
  exit 1
fi

log "reload: starting; validating config ${OUTPUT_CFG}"
if ! haproxy -c -f "${OUTPUT_CFG}" >/dev/null 2>&1; then
  err "haproxy -c failed for ${OUTPUT_CFG}; aborting reload"
  exit 1
fi
log "reload: validation succeeded"

if ! acquire_lock; then
  err "reload: failed to acquire lock; aborting"
  exit 1
fi

# Record old pid (if any)
OLDPID=""
if [ -f "${HAPROXY_PID_FILE}" ]; then
  OLDPID=$(cat "${HAPROXY_PID_FILE}" 2>/dev/null || true)
fi

log "reload: old pidfile=${HAPROXY_PID_FILE} oldpid=${OLDPID:-<none>}"

# Start new master-worker instance detached so consul-template hook returns quickly.
# New master will attempt a graceful handover if we pass -sf <OLDPID>.
# Redirect output to LOGFILE for diagnostics.
if [ -n "${OLDPID}" ] && kill -0 "${OLDPID}" 2>/dev/null; then
  log "reload: launching new master with -sf ${OLDPID}"
  # start detached; nohup may not exist on some minimal images - fall back to background if needed
  if command -v nohup >/dev/null 2>&1; then
    nohup haproxy -f "${OUTPUT_CFG}" -p "${HAPROXY_PID_FILE}" -W -sf "${OLDPID}" >> "${LOGFILE}" 2>&1 &
  else
    haproxy -f "${OUTPUT_CFG}" -p "${HAPROXY_PID_FILE}" -W -sf "${OLDPID}" >> "${LOGFILE}" 2>&1 &
  fi
else
  log "reload: launching new master (no old pid to -sf)"
  if command -v nohup >/dev/null 2>&1; then
    nohup haproxy -f "${OUTPUT_CFG}" -p "${HAPROXY_PID_FILE}" -W >> "${LOGFILE}" 2>&1 &
  else
    haproxy -f "${OUTPUT_CFG}" -p "${HAPROXY_PID_FILE}" -W >> "${LOGFILE}" 2>&1 &
  fi
fi

# Wait a short time for pidfile to be written (start-up)
elapsed=0
NEWPID=""
while [ "$elapsed" -lt "${START_TIMEOUT}" ]; do
  if [ -f "${HAPROXY_PID_FILE}" ]; then
    NEWPID=$(cat "${HAPROXY_PID_FILE}" 2>/dev/null || true)
    # sanity check: make sure PID is numeric and process exists
    if [ -n "${NEWPID}" ] && kill -0 "${NEWPID}" 2>/dev/null; then
      break
    fi
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if [ -n "${NEWPID}" ] && kill -0 "${NEWPID}" 2>/dev/null; then
  log "reload: success; new master pid=${NEWPID}"
  # release lock (trap will clean up), exit success
  exit 0
else
  err "reload: failed to detect new master pid after ${START_TIMEOUT}s"
  # Try to find any backgrounded haproxy processes that started and kill them (best-effort)
  # Look for haproxy processes that were started recently (owner may be same UID)
  pids=$(ps -eo pid,comm | awk '$2=="haproxy"{print $1}' || true)
  for p in $pids; do
    # skip old pid if present
    if [ -n "${OLDPID}" ] && [ "${p}" = "${OLDPID}" ]; then
      continue
    fi
    # attempt to kill the candidate (best-effort)
    kill -TERM "${p}" 2>/dev/null || true
  done
  err "reload: aborted and attempted cleanup"
  exit 1
fi
