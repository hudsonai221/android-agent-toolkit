#!/data/data/com.termux/files/usr/bin/bash
# aat logs — unified log viewer for OpenClaw on Android
#
# Sources:
#   gateway   — OpenClaw gateway commands log (~/.openclaw/logs/commands.log)
#   watchdog  — AAT watchdog log ($PREFIX/tmp/aat-watchdog.log)
#   cron      — OpenClaw cron run logs (~/.openclaw/cron/runs/*.jsonl)
#   all       — All sources merged (default)
#
# Usage: aat logs [source] [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- Config ---
GATEWAY_LOG="$HOME/.openclaw/logs/commands.log"
WATCHDOG_LOG="${AAT_LOG_DIR:-/data/data/com.termux/files/usr/tmp}/aat-watchdog.log"
CRON_RUNS_DIR="$HOME/.openclaw/cron/runs"

# --- Parse args ---
SOURCE="all"  # all | gateway | watchdog | cron
LINES=50
FOLLOW=false
GREP_PATTERN=""
SINCE=""
OUTPUT_FORMAT="human"  # human | json | raw

usage() {
  cat <<EOF
Usage: aat logs [source] [options]

View logs from OpenClaw gateway, watchdog, and cron jobs.

Sources:
  all        All sources (default)
  gateway    Gateway commands log
  watchdog   Watchdog activity log
  cron       Cron job run logs

Options:
  -n, --lines N       Number of lines to show (default: ${LINES})
  -f, --follow        Follow log output (tail -f, gateway/watchdog only)
  --grep PATTERN      Filter lines matching pattern
  --since TIME        Show entries since TIME (e.g., "1h", "2d", "2026-03-09")
  --json              Output as JSON
  --raw               Raw log output (no formatting)
  -h, --help          Show this help

Examples:
  aat logs                     # Last 50 lines from all sources
  aat logs watchdog            # Watchdog log
  aat logs gateway -n 100      # Last 100 gateway log entries
  aat logs cron                # Recent cron job runs
  aat logs --grep "restart"    # Search all logs for "restart"
  aat logs watchdog -f         # Follow watchdog log
  aat logs --since 1h          # Entries from the last hour
EOF
}

# First positional arg might be a source
case "${1:-}" in
  all|gateway|watchdog|cron)
    SOURCE="$1"; shift ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--lines) LINES="$2"; shift 2 ;;
    -f|--follow) FOLLOW=true; shift ;;
    --grep) GREP_PATTERN="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    --raw) OUTPUT_FORMAT="raw"; shift ;;
    -h|--help) usage; exit 0 ;;
    all|gateway|watchdog|cron) SOURCE="$1"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Since parsing ---
# Convert --since value to a Unix timestamp for filtering
since_ts=0
if [[ -n "$SINCE" ]]; then
  case "$SINCE" in
    *h)
      hours="${SINCE%h}"
      since_ts=$(( $(date +%s) - hours * 3600 ))
      ;;
    *d)
      days="${SINCE%d}"
      since_ts=$(( $(date +%s) - days * 86400 ))
      ;;
    *m)
      mins="${SINCE%m}"
      since_ts=$(( $(date +%s) - mins * 60 ))
      ;;
    *)
      # Try to parse as a date
      since_ts=$(date -d "$SINCE" +%s 2>/dev/null || echo 0)
      ;;
  esac
fi

# --- Log reading functions ---

read_gateway_log() {
  if [[ ! -f "$GATEWAY_LOG" ]]; then
    echo "# No gateway log found at $GATEWAY_LOG" >&2
    return
  fi

  if $FOLLOW; then
    tail -f "$GATEWAY_LOG"
    return
  fi

  local content
  content=$(tail -n "$LINES" "$GATEWAY_LOG")

  if [[ -n "$GREP_PATTERN" ]]; then
    content=$(echo "$content" | grep -i "$GREP_PATTERN" || true)
  fi

  if (( since_ts > 0 )); then
    # Gateway log is JSONL — filter by timestamp field
    content=$(echo "$content" | while IFS= read -r line; do
      ts=$(echo "$line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')
      if [[ -n "$ts" ]]; then
        line_ts=$(date -d "$ts" +%s 2>/dev/null || echo 0)
        if (( line_ts >= since_ts )); then
          echo "$line"
        fi
      fi
    done)
  fi

  if [[ "$OUTPUT_FORMAT" == "raw" || "$OUTPUT_FORMAT" == "json" ]]; then
    echo "$content"
  else
    # Format JSONL into readable lines
    echo "$content" | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      ts=$(echo "$line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')
      action=$(echo "$line" | sed -n 's/.*"action":"\([^"]*\)".*/\1/p')
      session=$(echo "$line" | sed -n 's/.*"sessionKey":"\([^"]*\)".*/\1/p')
      source_ch=$(echo "$line" | sed -n 's/.*"source":"\([^"]*\)".*/\1/p')
      # Shorten timestamp
      short_ts="${ts%.*}"
      short_ts="${short_ts/T/ }"
      echo -e "  ${DIM}${short_ts}${RESET}  ${BLUE}${action}${RESET}  ${session}  ${DIM}${source_ch}${RESET}"
    done
  fi
}

read_watchdog_log() {
  if [[ ! -f "$WATCHDOG_LOG" ]]; then
    echo "# No watchdog log found at $WATCHDOG_LOG" >&2
    return
  fi

  if $FOLLOW; then
    tail -f "$WATCHDOG_LOG"
    return
  fi

  local content
  content=$(tail -n "$LINES" "$WATCHDOG_LOG")

  if [[ -n "$GREP_PATTERN" ]]; then
    content=$(echo "$content" | grep -i "$GREP_PATTERN" || true)
  fi

  if (( since_ts > 0 )); then
    content=$(echo "$content" | while IFS= read -r line; do
      # Watchdog format: [YYYY-MM-DD HH:MM:SS UTC] [LEVEL] msg
      ts=$(echo "$line" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
      if [[ -n "$ts" ]]; then
        line_ts=$(date -d "$ts" +%s 2>/dev/null || echo 0)
        if (( line_ts >= since_ts )); then
          echo "$line"
        fi
      fi
    done)
  fi

  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo "$content"
  else
    # Colorize watchdog output
    echo "$content" | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" == *"[ERROR]"* ]]; then
        echo -e "  ${RED}${line}${RESET}"
      elif [[ "$line" == *"[WARN]"* ]]; then
        echo -e "  ${YELLOW}${line}${RESET}"
      else
        echo -e "  ${line}"
      fi
    done
  fi
}

read_cron_logs() {
  if [[ ! -d "$CRON_RUNS_DIR" ]]; then
    echo "# No cron runs directory found at $CRON_RUNS_DIR" >&2
    return
  fi

  # Build job ID → name map from jobs.json (written to temp file for subshell access)
  local jobs_file="$HOME/.openclaw/cron/jobs.json"
  local job_map_file
  job_map_file=$(mktemp "${TMPDIR:-/tmp}/aat-jobmap.XXXXXX")
  if [[ -f "$jobs_file" ]] && command -v python3 &>/dev/null; then
    python3 -c "
import json
try:
    with open('$jobs_file') as f:
        data = json.load(f)
    jobs = data.get('jobs', data) if isinstance(data, dict) else data
    if not isinstance(jobs, list):
        jobs = []
    for j in jobs:
        jid = j.get('id','')
        jname = j.get('name','')
        if jid and jname:
            print(jid + '|' + jname)
except: pass
" > "$job_map_file" 2>/dev/null
  fi

  # Get the most recent cron run files by modification time
  local run_files
  run_files=$(find "$CRON_RUNS_DIR" -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n "$LINES")

  if [[ -z "$run_files" ]]; then
    rm -f "$job_map_file"
    echo "# No cron runs found" >&2
    return
  fi

  if [[ "$OUTPUT_FORMAT" == "raw" ]]; then
    echo "$run_files" | awk '{print $2}' | while read -r f; do
      echo "=== $(basename "$f") ==="
      cat "$f"
      echo ""
    done
    return
  fi

  # Parse and display cron run summaries
  echo "$run_files" | while read -r mtime filepath; do
    [[ -z "$filepath" ]] && continue

    # Extract run/job ID from filename
    run_id=$(basename "$filepath" .jsonl)

    # Read first line for metadata
    first_line=$(head -1 "$filepath" 2>/dev/null)
    last_line=$(tail -1 "$filepath" 2>/dev/null)

    # Get job ID from JSONL (may differ from filename for run-specific files)
    job_id=$(echo "$first_line" | sed -n 's/.*"jobId":"\([^"]*\)".*/\1/p')
    [[ -z "$job_id" ]] && job_id="$run_id"

    # Look up job name from temp map file, fall back to ID prefix
    job_name=$(grep "^${job_id}|" "$job_map_file" 2>/dev/null | head -1 | cut -d'|' -f2 || true)
    [[ -z "$job_name" ]] && job_name="${job_id:0:12}…"

    # Get timestamp (might be epoch ms)
    ts_raw=$(echo "$first_line" | sed -n 's/.*"ts":\([0-9]*\).*/\1/p')
    ts=""
    if [[ -n "$ts_raw" ]]; then
      # Convert epoch ms to readable
      ts_s=$(( ts_raw / 1000 ))
      ts=$(date -u -d "@$ts_s" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || true)
    fi
    # Fall back to ISO timestamp
    if [[ -z "$ts" ]]; then
      ts=$(echo "$first_line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')
      ts="${ts%.*}"
      ts="${ts/T/ }"
    fi

    # Get status from last line
    status=$(echo "$last_line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')

    # Check time filter
    if (( since_ts > 0 )) && [[ -n "$ts_raw" ]]; then
      if (( ts_raw / 1000 < since_ts )); then
        continue
      fi
    fi

    # Check grep filter
    if [[ -n "$GREP_PATTERN" ]]; then
      if ! grep -qi "$GREP_PATTERN" "$filepath" 2>/dev/null; then
        continue
      fi
    fi

    # Format status indicator
    status_icon="${DIM}?${RESET}"
    case "$status" in
      ok|success) status_icon="${GREEN}✓${RESET}" ;;
      error|failed) status_icon="${RED}✗${RESET}" ;;
      running) status_icon="${YELLOW}⟳${RESET}" ;;
    esac

    line_count=$(wc -l < "$filepath")

    echo -e "  ${status_icon} ${DIM}${ts}${RESET}  ${BLUE}${job_name}${RESET}  ${DIM}(${line_count} events)${RESET}"
  done

  rm -f "$job_map_file"
}

# --- Main output ---

if [[ "$OUTPUT_FORMAT" == "human" ]] && ! $FOLLOW; then
  echo -e "${BOLD}Android Agent Toolkit — Logs${RESET}"
  echo ""
fi

case "$SOURCE" in
  gateway)
    [[ "$OUTPUT_FORMAT" == "human" ]] && ! $FOLLOW && echo -e "${BOLD}Gateway${RESET} (${GATEWAY_LOG})"
    read_gateway_log
    ;;
  watchdog)
    [[ "$OUTPUT_FORMAT" == "human" ]] && ! $FOLLOW && echo -e "${BOLD}Watchdog${RESET} (${WATCHDOG_LOG})"
    read_watchdog_log
    ;;
  cron)
    [[ "$OUTPUT_FORMAT" == "human" ]] && ! $FOLLOW && echo -e "${BOLD}Cron Runs${RESET} (${CRON_RUNS_DIR})"
    read_cron_logs
    ;;
  all)
    if $FOLLOW; then
      echo "Error: --follow requires a specific source (gateway or watchdog)" >&2
      exit 1
    fi
    echo -e "${BOLD}Gateway${RESET} (${GATEWAY_LOG})"
    read_gateway_log
    echo ""
    echo -e "${BOLD}Watchdog${RESET} (${WATCHDOG_LOG})"
    read_watchdog_log
    echo ""
    echo -e "${BOLD}Cron Runs${RESET} (recent)"
    LINES=10 read_cron_logs
    ;;
esac
