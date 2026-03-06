#!/data/data/com.termux/files/usr/bin/bash
# Reads JSON health output from stdin, sends Termux notification if problems detected.
# Usage: aat health --json | ./scripts/alert-on-problem.sh

set -euo pipefail

json=$(cat)
overall=$(echo "$json" | jq -r '.overall' 2>/dev/null)

if [[ "$overall" == "ok" ]]; then
  exit 0
fi

# Build alert message
problems=$(echo "$json" | jq -r '.problems[]' 2>/dev/null || true)
warnings=$(echo "$json" | jq -r '.warnings[]' 2>/dev/null || true)

title="AAT Health"
[[ "$overall" == "critical" ]] && title="⚠️ AAT CRITICAL"
[[ "$overall" == "warning" ]] && title="AAT Warning"

message=""
[[ -n "$problems" ]] && message="${problems}"
[[ -n "$warnings" ]] && message="${message:+${message}\n}${warnings}"

# Send notification via termux-notification if available
if command -v termux-notification &>/dev/null; then
  termux-notification \
    --title "$title" \
    --content "$(echo -e "$message")" \
    --priority high \
    --id "aat-health" \
    2>/dev/null
fi

# Also print to stderr for cron logs
echo -e "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${title}: ${message}" >&2

exit 0
