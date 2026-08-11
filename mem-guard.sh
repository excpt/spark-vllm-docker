#!/usr/bin/env bash
# Dead-simple hard memory wall for GB10 unified memory. cgroups mis-account GPU pages, so
# we don't use them — we just read `free` (which counts ALL used memory) and kill the
# container the instant used crosses the limit. Host survives; the model dies instead.
#   usage: mem-guard.sh <container> <limit_gb>
set -euo pipefail
C="${1:-spark-laguna}"
LIMIT_MB=$(( "${2:-100}" * 1024 ))
echo "guard: killing $C when used >= ${2:-100}GB (${LIMIT_MB}MB); polling 2s"
while true; do
  used=$(free -m | awk '/^Mem:/{print $3}')
  printf '%s used=%5sMB free=%5sMB\n' "$(date +%T)" "$used" "$(free -m | awk '/^Mem:/{print $4}')"
  if [ "$used" -ge "$LIMIT_MB" ]; then
    echo "!!! ${used}MB >= ${LIMIT_MB}MB — KILLING $C NOW"
    docker kill "$C" 2>&1 || true
    exit 1
  fi
  sleep 2
done
