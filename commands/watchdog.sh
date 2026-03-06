#!/data/data/com.termux/files/usr/bin/bash
# aat watchdog — monitor and auto-restart the OpenClaw gateway
#
# Runs as a foreground loop. Designed for:
#   - Direct invocation: aat watchdog
#   - Background via nohup: nohup aat watchdog &
#   - Cron-triggered one-shot: aat watchdog --once
#
# Features:
#   - Process + RPC health checking
#   - Auto-restart with exponential backoff
#   - Restart cap per time window (prevents restart storms)
#   - Logging to file and stdout
#   - Optional termux-notification on events
#   - Pidfile to prevent duplicate watchdogs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- Defaults ---
INTERVAL=60               # seconds between checks
MAX_RESTARTS=5            # max restarts per window
RESTART_WINDOW=3600       # window in seconds (1 hour)
INITIAL_BACKOFF=10        # seconds before first restart attempt
MAX_BACKOFF=300           # max backoff between restarts (5 min)
RPC_TIMEOUT=5             # seconds to wait for RPC probe
LOG_FILE="${AAT_LOG_DIR:-/data/data/com.termux/files/usr/tmp}/aat-watchdog.log"
PIDFILE="${AAT_RUN_DIR:-/data/data/com.termux/files/usr/tmp}/aat-watchdog.pid"
ONE_SHOT=false
DRY_RUN=false
NOTIFY=true               # send termux-notification on events
QUIET=false

# --- Parse args ---
usage() {
  cat <<EOF
Usage: aat watchdog [options]

Monitor and auto-restart the OpenClaw gateway.

Options:
  --interval SEC      Check interval (default: ${INTERVAL}s)
  --max-restarts N    Max restarts per window (default: ${MAX_RESTARTS})
  --window SEC        Restart window in seconds (default: ${RESTART_WINDOW}s)
  --once              Run a single check cycle, then exit
  --dry-run           Check only, don't actually restart
  --no-notify         Don't send termux-notification
  --quiet             Suppress stdout (still logs to file)
  --log FILE          Log file path (default: ${LOG_FILE})
  --pidfile FILE      Pidfile path (default: ${PIDFILE})
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)   INTERVAL="$2"; shift 2 ;;
    --max-restarts) MAX_RESTARTS="$2"; shift 2 ;;
    --window)     RESTART_WINDOW="$2"; shift 2 ;;
    --once)       ONE_SHOT=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --no-notify)  NOTIFY=false; shift ;;
    --quiet)      QUIET=true; shift ;;
    --log)        LOG_FILE="$2"; shift 2 ;;
    --pidfile)    PIDFILE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Logging ---
log() {
  local level="$1" msg="$2"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  local line="[${timestamp}] [${level}] ${msg}"

  # Always write to log file
  echo "$line" >> "$LOG_FILE"

  # Write to stdout unless quiet
  if ! $QUIET; then
    case "$level" in
      ERROR) echo -e "${RED}${line}${RESET}" ;;
      WARN)  echo -e "${YELLOW}${line}${RESET}" ;;
      INFO)  echo -e "${line}" ;;
      *)     echo "$line" ;;
    esac
  fi
}

# --- Notification ---
notify() {
  local title="$1" message="$2" priority="${3:-default}"
  if $NOTIFY && command -v termux-notification &>/dev/null; then
    termux-notification \
      --title "$title" \
      --content "$message" \
      --priority "$priority" \
      --id "aat-watchdog" \
      2>/dev/null || true
  fi
}

# --- Pidfile management ---
check_pidfile() {
  if [[ -f "$PIDFILE" ]]; then
    local existing_pid
    existing_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "Watchdog already running (PID ${existing_pid}). Use --pidfile for a different instance." >&2
      exit 1
    fi
    # Stale pidfile, remove it
    rm -f "$PIDFILE"
  fi
}

write_pidfile() {
  echo $$ > "$PIDFILE"
}

cleanup_pidfile() {
  rm -f "$PIDFILE"
}

# --- Gateway health check ---
check_gateway_process() {
  # Check if any openclaw-related process is running
  if pgrep -f "openclaw" > /dev/null 2>&1; then
    return 0
  fi
  return 1
}

check_gateway_rpc() {
  local port="${OPENCLAW_PORT:-18789}"
  if command -v curl &>/dev/null; then
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time "$RPC_TIMEOUT" \
      "http://127.0.0.1:${port}/" 2>/dev/null) || true
    if [[ "$http_code" =~ ^[23] ]]; then
      return 0
    fi
  fi
  return 1
}

# Full health check — returns: "ok", "process_down", "rpc_down"
check_health() {
  if ! check_gateway_process; then
    echo "process_down"
    return
  fi
  if ! check_gateway_rpc; then
    echo "rpc_down"
    return
  fi
  echo "ok"
}

# --- Restart logic ---
restart_gateway() {
  local node_bin
  node_bin=$(find_node) || {
    log "ERROR" "Cannot find node binary — unable to restart gateway"
    return 1
  }

  local openclaw_bin
  openclaw_bin=$(find_openclaw) || {
    log "ERROR" "Cannot find openclaw binary — unable to restart gateway"
    return 1
  }

  if $DRY_RUN; then
    log "INFO" "[DRY RUN] Would restart gateway via: ${node_bin} ${openclaw_bin} gateway restart"
    return 0
  fi

  log "INFO" "Attempting gateway restart..."

  # Try 'gateway restart' first; if the process is dead, use 'gateway start'
  local output
  if check_gateway_process; then
    output=$("$node_bin" "$openclaw_bin" gateway restart 2>&1) || true
  else
    output=$("$node_bin" "$openclaw_bin" gateway start 2>&1) || true
  fi

  log "INFO" "Gateway command output: $(echo "$output" | head -5 | tr '\n' ' ')"

  # Wait a moment for the process to come up
  sleep 5

  # Verify it came back
  local health
  health=$(check_health)
  if [[ "$health" == "ok" ]]; then
    log "INFO" "Gateway restarted successfully"
    notify "🔄 Gateway Restarted" "OpenClaw gateway was down and has been restarted." "high"
    return 0
  else
    log "ERROR" "Gateway restart failed — health: ${health}"
    notify "⚠️ Gateway Restart Failed" "Attempted restart but gateway is still ${health}." "max"
    return 1
  fi
}

# --- Restart tracking (for rate limiting) ---
declare -a RESTART_TIMES=()

record_restart() {
  RESTART_TIMES+=("$(date +%s)")
}

restarts_in_window() {
  local now count cutoff
  now=$(date +%s)
  cutoff=$(( now - RESTART_WINDOW ))
  count=0

  # Clean old entries and count recent ones
  local new_times=()
  for t in "${RESTART_TIMES[@]}"; do
    if (( t > cutoff )); then
      new_times+=("$t")
      (( count++ ))
    fi
  done
  RESTART_TIMES=("${new_times[@]}")
  echo "$count"
}

# --- Main loop ---
main() {
  # Pidfile check (skip for one-shot)
  if ! $ONE_SHOT; then
    check_pidfile
    write_pidfile
    trap cleanup_pidfile EXIT
  fi

  # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"

  if $ONE_SHOT; then
    log "INFO" "Watchdog one-shot check"
  else
    log "INFO" "Watchdog started (interval=${INTERVAL}s, max_restarts=${MAX_RESTARTS}/${RESTART_WINDOW}s)"
  fi

  local consecutive_failures=0
  local current_backoff=$INITIAL_BACKOFF

  while true; do
    local health
    health=$(check_health)

    if [[ "$health" == "ok" ]]; then
      # All good — reset failure tracking
      if (( consecutive_failures > 0 )); then
        log "INFO" "Gateway healthy again after ${consecutive_failures} failure(s)"
        consecutive_failures=0
        current_backoff=$INITIAL_BACKOFF
      fi

      if $ONE_SHOT; then
        log "INFO" "Gateway healthy"
        exit 0
      fi
    else
      (( consecutive_failures++ ))
      log "WARN" "Gateway unhealthy: ${health} (failure #${consecutive_failures})"

      # Check restart budget
      local recent_restarts
      recent_restarts=$(restarts_in_window)

      if (( recent_restarts >= MAX_RESTARTS )); then
        log "ERROR" "Restart limit reached (${recent_restarts}/${MAX_RESTARTS} in last ${RESTART_WINDOW}s) — backing off"
        notify "🛑 Watchdog: Restart Limit" "Hit ${MAX_RESTARTS} restarts in ${RESTART_WINDOW}s. Manual intervention needed." "max"

        if $ONE_SHOT; then
          exit 2
        fi
      else
        # Apply backoff before restart
        if (( consecutive_failures > 1 )); then
          log "INFO" "Backoff: waiting ${current_backoff}s before restart attempt"
          sleep "$current_backoff"
          # Exponential backoff with cap
          current_backoff=$(( current_backoff * 2 ))
          (( current_backoff > MAX_BACKOFF )) && current_backoff=$MAX_BACKOFF

          # Re-check — maybe it recovered during backoff
          health=$(check_health)
          if [[ "$health" == "ok" ]]; then
            log "INFO" "Gateway recovered during backoff"
            consecutive_failures=0
            current_backoff=$INITIAL_BACKOFF
            if $ONE_SHOT; then
              exit 0
            fi
            sleep "$INTERVAL"
            continue
          fi
        fi

        # Attempt restart
        if restart_gateway; then
          record_restart
          consecutive_failures=0
          current_backoff=$INITIAL_BACKOFF
        else
          record_restart
        fi
      fi

      if $ONE_SHOT; then
        # Re-check after restart attempt
        health=$(check_health)
        if [[ "$health" == "ok" ]]; then
          exit 0
        else
          exit 2
        fi
      fi
    fi

    sleep "$INTERVAL"
  done
}

main
