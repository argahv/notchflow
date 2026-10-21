#!/bin/bash
# Observe NotchFlow's idle/interactive CPU and resident memory without recording desktop content.
set -euo pipefail
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This profiler requires macOS." >&2
  exit 1
fi
DURATION="${1:-1800}"
INTERVAL="${2:-10}"
[[ "$DURATION" =~ ^[0-9]+$ && "$INTERVAL" =~ ^[0-9]+$ ]] || {
  echo "Usage: bash Scripts/profile.sh [duration_seconds] [interval_seconds]" >&2; exit 2;
}
(( DURATION > 0 && INTERVAL > 0 )) || { echo "Both arguments must be positive." >&2; exit 2; }
PID="$(pgrep -x NotchFlow | head -n 1 || true)"
[[ -n "$PID" ]] || { echo "Start NotchFlow before profiling." >&2; exit 1; }
OUT="${NOTCHFLOW_PROFILE_OUTPUT:-notchflow-profile-$(date +%Y%m%d-%H%M%S).csv}"
printf 'timestamp,pid,cpu_percent,rss_kb\n' > "$OUT"
echo "Sampling PID $PID for $DURATION seconds, every $INTERVAL seconds -> $OUT"
remaining="$DURATION"
while (( remaining >= 0 )); do
  sample="$(ps -p "$PID" -o %cpu=,rss= | awk 'NF==2 {print $1 "," $2}')"
  if [[ -z "$sample" ]]; then echo "NotchFlow exited; stopping." >&2; break; fi
  printf '%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PID" "$sample" >> "$OUT"
  (( remaining == 0 )) && break
  sleep_for="$INTERVAL"
  (( remaining < INTERVAL )) && sleep_for="$remaining"
  sleep "$sleep_for"
  remaining=$((remaining - sleep_for))
done
echo "Saved $OUT. RSS is resident memory, not proof of a leak. Compare repeated idle/interactive runs."
