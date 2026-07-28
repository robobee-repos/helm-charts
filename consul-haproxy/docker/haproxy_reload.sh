#!/bin/sh
# haproxy_reload.sh
# Validate and reload HAProxy; write logs to stdout/stderr so Docker captures them.
#
# Environment (optional):
#   OUTPUT_CFG         - path to the rendered haproxy config (default: /etc/haproxy/haproxy.cfg)
#   HAPROXY_PID_FILE   - path to pidfile (default: /var/run/haproxy.pid)
#   START_TIMEOUT      - seconds to wait for new pidfile (default: 5)
#   LOCKDIR            - lockdir to serialize reloads (default: /var/run/haproxy-reload.lock)
#   LOG_LEVEL          - "DEBUG" to enable verbose logs and shell xtrace (default: "INFO")

OUTPUT_CFG="${OUTPUT_CFG:-/etc/haproxy/haproxy.cfg}"
HAPROXY_PID_FILE="${HAPROXY_PID_FILE:-/var/run/haproxy.pid}"
START_TIMEOUT="${START_TIMEOUT:-5}"
LOCKDIR="${LOCKDIR:-/var/run/haproxy-reload.lock}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

log() {
  printf '%s %s\n' "$(date -Is)" "$*"
}

err() {
  printf '%s %s\n' "$(date -Is)" "ERROR: $*" >&2
}

debug() {
  [ "${LOG_LEVEL:-INFO}" = "DEBUG" ] && log "DEBUG: $*"
}

# enable xtrace in DEBUG mode for easier troubleshooting
if [ "${LOG_LEVEL:-INFO}" = "DEBUG" ]; then
  # set -x may not be desired in some minimal shells, but it's useful for debugging.
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

# Validate config file existence
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
debug "lockdir=${LOCKDIR} start_timeout=${START_TIMEOUT} log_level=${LOG_LEVEL}"

# Decide how to redirect child's stdout/stderr so Docker captures it:
# Prefer /proc/1/fd/1 and /proc/1/fd/2 (PID 1 = container init). Fall back to /dev/stdout /dev/stderr if available, else /dev/null.
STDOUT_TARGET="/dev/null"
STDERR_TARGET="/dev/null"
if [ -e "/proc/1/fd/1" ]; then
  STDOUT_TARGET="/proc/1/fd/1"
fi
if [ -e "/proc/1/fd/2" ]; then
  STDERR_TARGET="/proc/1/fd/2"
fi
# fallback to /dev/stdout and /dev/stderr if proc fds not available
if [ "${STDOUT_TARGET}" = "/dev/null" ] && [ -e "/dev/stdout" ]; then
  STDOUT_TARGET="/dev/stdout"
fi
if [ "${STDERR_TARGET}" = "/dev/null" ] && [ -e "/dev/stderr" ]; then
  STDERR_TARGET="/dev/stderr"
fi

debug "stdout_target=${STDOUT_TARGET} stderr_target=${STDERR_TARGET}"

# Start new master-worker instance detached so consul-template hook returns quickly.
# New master will attempt a graceful handover if we pass -sf <OLDPID>.
if [ -n "${OLDPID}" ] && kill -0 "${OLDPID}" 2>/dev/null; then
  log "reload: launching new master with -sf ${OLDPID}"
  debug "exec: haproxy -f ${OUTPUT_CFG} -p ${HAPROXY_PID_FILE} -W -sf ${OLDPID}"
  # Start in background and redirect stdout/stderr to container stdout/stderr target.
  # Use backgrounding so we can control redirection.
  haproxy -f "${OUTPUT_CFG}" -p "${HAPROXY_PID_FILE}" -W -sf "${OLDPID}" >"${STDOUT_TARGET}" 2>"${STDERR_TARGET}" &
else
  log "reload: launching new master (no old pid to -sf)"
  debug "exec: haproxy -f ${OUTPUT_CFG} -p ${HAPROXY_PID_FILE} -W"
  haproxy -f "${OUTPUT_CFG}" -p "${HAPROXY_PID_FILE}" -W >"${STDOUT_TARGET}" 2>"${STDERR_TARGET}" &
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
  # Best-effort cleanup: attempt to find and terminate recent haproxy children that aren't the old pid.
  debug "attempting cleanup of stray haproxy pids"
  pids=$(ps -eo pid,comm | awk '$2=="haproxy"{print $1}' | tr '\n' ' ' || true)
  for p in $pids; do
    # skip old pid if present
    if [ -n "${OLDPID}" ] && [ "${p}" = "${OLDPID}" ]; then
      continue
    fi
    # attempt to kill the candidate (best-effort)
    debug "killing stray pid ${p}"
    kill -TERM "${p}" 2>/dev/null || true
  done
  err "reload: aborted and attempted cleanup"
  exit 1
fi
