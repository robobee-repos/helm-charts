#!/bin/bash
set -euo pipefail

CFG="/etc/haproxy/haproxy.cfg"
PIDFILE="/var/run/haproxy.pid"

# Validate config first
if ! haproxy -c -f "$CFG"; then
  echo "haproxy config validation failed, skipping reload" >&2
  exit 1
fi

# Graceful reload: if old pid exists, start new process and tell old to finish
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE")
  echo "Reloading haproxy: starting new process and stopping old pid $OLD_PID"
  haproxy -f "$CFG" -p "$PIDFILE" -sf "$OLD_PID"
else
  echo "No pid file present, starting haproxy"
  haproxy -f "$CFG" -p "$PIDFILE" -db
fi
