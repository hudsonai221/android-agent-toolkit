#!/data/data/com.termux/files/usr/bin/bash
# aat status — combined system dashboard for OpenClaw on Android
#
# One-glance view of:
#   - Gateway: process, RPC, port, PID, uptime
#   - Watchdog: running/stopped, last check, restart count
#   - Backups: last backup time, size, count
#   - Resources: RAM, swap, storage
#   - Battery: level, temperature, plugged status
#   - System: load, uptime
#
# Usage: aat status [--json|--brief]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- Config ---
BACKUP_DIR="$HOME/backups"
WATCHDOG_LOG="${AAT_LOG_DIR:-/data/data/com.termux/files/usr/tmp}/aat-watchdog.log"
WATCHDOG_PIDFILE="${AAT_RUN_DIR:-/data/data/com.termux/files/usr/tmp}/aat-watchdog.pid"
GATEWAY_PORT="${OPENCLAW_PORT:-18789}"

# --- Parse args ---
OUTPUT_FORMAT="human"  # human | json | brief
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  OUTPUT_FORMAT="json"; shift ;;
    --brief) OUTPUT_FORMAT="brief"; shift ;;
    -h|--help)
      echo "Usage: aat status [--json|--brief]"
      echo ""
      echo "Combined system dashboard for OpenClaw on Android."
      echo ""
      echo "Options:"
      echo "  --json    Output as JSON (for scripting)"
      echo "  --brief   One-line summary"
      echo "  -h        Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Collect data ---
overall="ok"
problems=()
warnings=()

# ── Gateway ──

gateway_pid=""
gateway_running=false
# Find the actual gateway process (exclude pgrep itself and scripts)
gateway_pid=$(pgrep -f "openclaw-gateway|openclaw gateway" 2>/dev/null | head -1) || true
if [[ -z "$gateway_pid" ]]; then
  # Fall back to any openclaw process (filter self)
  gateway_pid=$(pgrep -f "openclaw" 2>/dev/null | grep -v "^$$\$" | head -1) || true
fi
if [[ -n "$gateway_pid" ]] && kill -0 "$gateway_pid" 2>/dev/null; then
  gateway_running=true
fi

gateway_rpc="unknown"
if command -v curl &>/dev/null; then
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null) || true
  if [[ "$http_code" =~ ^[23] ]]; then
    gateway_rpc="ok"
  else
    gateway_rpc="unreachable"
  fi
fi

# Gateway process uptime (how long the PID has been running)
gateway_uptime=""
gateway_uptime_s=""
if $gateway_running && [[ -n "$gateway_pid" ]]; then
  # ps ELAPSED format: [[DD-]HH:]MM:SS
  gw_etime=$(ps -o etime= -p "$gateway_pid" 2>/dev/null | grep -v '^[[:space:]]*$' | tr -d ' ') || true
  if [[ -n "$gw_etime" ]]; then
    # Parse elapsed time to seconds
    gw_secs=0
    if [[ "$gw_etime" == *-* ]]; then
      # DD-HH:MM:SS
      gw_d=${gw_etime%%-*}
      rest=${gw_etime#*-}
      gw_secs=$(( gw_d * 86400 ))
      gw_etime="$rest"
    fi
    # Now HH:MM:SS or MM:SS
    IFS=: read -ra parts <<< "$gw_etime"
    if (( ${#parts[@]} == 3 )); then
      gw_secs=$(( gw_secs + 10#${parts[0]} * 3600 + 10#${parts[1]} * 60 + 10#${parts[2]} ))
    elif (( ${#parts[@]} == 2 )); then
      gw_secs=$(( gw_secs + 10#${parts[0]} * 60 + 10#${parts[1]} ))
    fi
    gateway_uptime_s="$gw_secs"
    gw_days=$(( gw_secs / 86400 ))
    gw_hours=$(( (gw_secs % 86400) / 3600 ))
    gw_mins=$(( (gw_secs % 3600) / 60 ))
    if (( gw_days > 0 )); then
      gateway_uptime="${gw_days}d ${gw_hours}h ${gw_mins}m"
    elif (( gw_hours > 0 )); then
      gateway_uptime="${gw_hours}h ${gw_mins}m"
    else
      gateway_uptime="${gw_mins}m"
    fi
  fi
fi

if ! $gateway_running; then
  overall="critical"
  problems+=("Gateway not running")
elif [[ "$gateway_rpc" == "unreachable" ]]; then
  overall="critical"
  problems+=("Gateway RPC not responding")
fi

# ── Watchdog ──

watchdog_running=false
watchdog_pid=""
if [[ -f "$WATCHDOG_PIDFILE" ]]; then
  watchdog_pid=$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)
  if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
    watchdog_running=true
  fi
fi

# Check if watchdog is running via cron (system cron or OpenClaw cron)
watchdog_cron=false
if crontab -l 2>/dev/null | grep -q "aat.*watchdog"; then
  watchdog_cron=true
elif grep -q "watchdog" "$HOME/.openclaw/cron/jobs.json" 2>/dev/null; then
  watchdog_cron=true
fi

# Last watchdog activity from log
watchdog_last_check=""
watchdog_restarts=0
if [[ -f "$WATCHDOG_LOG" ]]; then
  # Last log line timestamp — extract [YYYY-MM-DD HH:MM:SS UTC] from log
  watchdog_last_check=$(tail -1 "$WATCHDOG_LOG" 2>/dev/null | sed -n 's/^\[\([^]]*\)\].*/\1/p' || true)
  # Count restarts in log
  watchdog_restarts=$(grep -c "Attempting gateway restart" "$WATCHDOG_LOG" 2>/dev/null || true)
  watchdog_restarts="${watchdog_restarts:-0}"
fi

# ── Backups ──

backup_count=0
backup_last=""
backup_last_size=""
backup_last_age=""
if [[ -d "$BACKUP_DIR" ]]; then
  # Find most recent backup
  latest_backup=$(find "$BACKUP_DIR" -maxdepth 1 -name 'aat-backup-*.tar.gz' -type f \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
  backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -name 'aat-backup-*.tar.gz' -type f 2>/dev/null | wc -l)

  if [[ -n "$latest_backup" ]]; then
    backup_last=$(basename "$latest_backup")
    backup_last_size=$(du -h "$latest_backup" 2>/dev/null | awk '{print $1}')
    # Age in days
    backup_mtime=$(stat -c%Y "$latest_backup" 2>/dev/null || echo 0)
    now=$(date +%s)
    backup_age_s=$(( now - backup_mtime ))
    backup_age_d=$(( backup_age_s / 86400 ))
    if (( backup_age_d == 0 )); then
      backup_last_age="today"
    elif (( backup_age_d == 1 )); then
      backup_last_age="1 day ago"
    else
      backup_last_age="${backup_age_d} days ago"
    fi

    # Warn if backup is old
    if (( backup_age_d > 7 )); then
      [[ "$overall" == "ok" ]] && overall="warning"
      warnings+=("Last backup is ${backup_age_d} days old")
    fi
  fi
fi

# ── Memory ──

mem_total_kb=$(meminfo_kb "MemTotal")
mem_available_kb=$(meminfo_kb "MemAvailable")
mem_used_kb=$(( mem_total_kb - mem_available_kb ))
mem_pct=$(( mem_used_kb * 100 / mem_total_kb ))

swap_total_kb=$(meminfo_kb "SwapTotal")
swap_free_kb=$(meminfo_kb "SwapFree")
swap_used_kb=$(( swap_total_kb - swap_free_kb ))

if (( mem_available_kb < 200000 )); then
  overall="critical"
  problems+=("RAM critically low: $(human_bytes $((mem_available_kb * 1024)))")
elif (( mem_available_kb < 500000 )); then
  [[ "$overall" == "ok" ]] && overall="warning"
  warnings+=("RAM low: $(human_bytes $((mem_available_kb * 1024)))")
fi

# ── Storage ──

storage_line=$(df -k /data 2>/dev/null | tail -1)
storage_total_kb=$(echo "$storage_line" | awk '{print $2}')
storage_avail_kb=$(echo "$storage_line" | awk '{print $4}')
storage_pct=$(echo "$storage_line" | awk '{print $5}' | tr -d '%')

if (( storage_avail_kb < 1048576 )); then
  overall="critical"
  problems+=("Storage critically low: $(human_bytes $((storage_avail_kb * 1024)))")
elif (( storage_avail_kb < 5242880 )); then
  [[ "$overall" == "ok" ]] && overall="warning"
  warnings+=("Storage low: $(human_bytes $((storage_avail_kb * 1024)))")
fi

# ── Battery ──

battery_pct=""
battery_status=""
battery_temp=""
battery_plugged=""
if command -v termux-battery-status &>/dev/null; then
  battery_json=$(termux-battery-status 2>/dev/null || echo "{}")
  if command -v jq &>/dev/null && [[ -n "$battery_json" ]]; then
    battery_pct=$(echo "$battery_json" | jq -r '.percentage // empty' 2>/dev/null)
    battery_status=$(echo "$battery_json" | jq -r '.status // empty' 2>/dev/null)
    battery_temp=$(echo "$battery_json" | jq -r '.temperature // empty' 2>/dev/null)
    battery_plugged=$(echo "$battery_json" | jq -r '.plugged // empty' 2>/dev/null)
  fi
fi

# ── System ──

load_1="n/a"
if loadavg=$(cat /proc/loadavg 2>/dev/null); then
  load_1=$(echo "$loadavg" | awk '{print $1}')
elif uptime_out=$(uptime 2>/dev/null); then
  # Parse "load average: X.XX, Y.YY, Z.ZZ" from uptime output
  load_1=$(echo "$uptime_out" | sed -n 's/.*load average: *\([0-9.]*\).*/\1/p')
  [[ -z "$load_1" ]] && load_1="n/a"
fi

uptime_human="unknown"
if uptime_raw=$(cat /proc/uptime 2>/dev/null); then
  uptime_s=$(echo "$uptime_raw" | awk '{print int($1)}')
  up_d=$(( uptime_s / 86400 ))
  up_h=$(( (uptime_s % 86400) / 3600 ))
  up_m=$(( (uptime_s % 3600) / 60 ))
  uptime_human="${up_d}d ${up_h}h ${up_m}m"
elif uptime_out=$(uptime 2>/dev/null); then
  # Parse "up X days, H:MM" from uptime output
  uptime_human=$(echo "$uptime_out" | sed 's/.*up *//' | sed 's/,.* user.*//' | sed 's/  */ /g')
fi

# --- Output ---

case "$OUTPUT_FORMAT" in
  json)
    cat <<EOJSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "overall": "${overall}",
  "gateway": {
    "running": ${gateway_running},
    "pid": ${gateway_pid:-null},
    "rpc": "${gateway_rpc}",
    "port": ${GATEWAY_PORT},
    "uptime": $(if [[ -n "$gateway_uptime" ]]; then echo "\"$gateway_uptime\""; else echo null; fi)
  },
  "watchdog": {
    "daemon_running": ${watchdog_running},
    "cron_active": ${watchdog_cron},
    "pid": ${watchdog_pid:-null},
    "last_check": $(if [[ -n "$watchdog_last_check" ]]; then echo "\"$watchdog_last_check\""; else echo null; fi),
    "restarts_24h": ${watchdog_restarts}
  },
  "backup": {
    "count": ${backup_count},
    "latest": $(if [[ -n "$backup_last" ]]; then echo "\"$backup_last\""; else echo null; fi),
    "latest_size": $(if [[ -n "$backup_last_size" ]]; then echo "\"$backup_last_size\""; else echo null; fi),
    "latest_age": $(if [[ -n "$backup_last_age" ]]; then echo "\"$backup_last_age\""; else echo null; fi)
  },
  "memory": {
    "total_mb": $(( mem_total_kb / 1024 )),
    "available_mb": $(( mem_available_kb / 1024 )),
    "used_pct": ${mem_pct},
    "swap_total_mb": $(( swap_total_kb / 1024 )),
    "swap_used_mb": $(( swap_used_kb / 1024 ))
  },
  "storage": {
    "total_gb": $(( storage_total_kb / 1048576 )),
    "available_gb": $(( storage_avail_kb / 1048576 )),
    "used_pct": ${storage_pct}
  },
  "battery": {
    "percentage": ${battery_pct:-null},
    "status": $(if [[ -n "$battery_status" ]]; then echo "\"$battery_status\""; else echo null; fi),
    "temperature": ${battery_temp:-null},
    "plugged": $(if [[ -n "$battery_plugged" ]]; then echo "\"$battery_plugged\""; else echo null; fi)
  },
  "system": {
    "load_1m": $(if [[ "$load_1" != "n/a" ]]; then echo "$load_1"; else echo null; fi),
    "uptime": "${uptime_human}"
  },
  "problems": [$(if [[ ${#problems[@]} -gt 0 ]]; then printf '"%s",' "${problems[@]}" | sed 's/,$//'; fi)],
  "warnings": [$(if [[ ${#warnings[@]} -gt 0 ]]; then printf '"%s",' "${warnings[@]}" | sed 's/,$//'; fi)]
}
EOJSON
    ;;

  brief)
    status_icon="✓"
    [[ "$overall" == "warning" ]] && status_icon="⚠"
    [[ "$overall" == "critical" ]] && status_icon="✗"

    gw="gw:up"
    $gateway_running || gw="gw:DOWN"

    wd="wd:off"
    $watchdog_running && wd="wd:daemon"
    $watchdog_cron && wd="wd:cron"

    bk="bk:none"
    [[ -n "$backup_last_age" ]] && bk="bk:${backup_last_age}"

    bat=""
    [[ -n "$battery_pct" ]] && bat=" bat:${battery_pct}%"

    echo "${status_icon} ${overall} | ${gw} rpc:${gateway_rpc} | ${wd} | ${bk} | ram:${mem_pct}% disk:${storage_pct}%${bat} | load:${load_1} up:${uptime_human}"
    ;;

  human)
    echo -e "${BOLD}Android Agent Toolkit — System Status${RESET}"
    echo -e "${DIM}$(date -u +"%Y-%m-%d %H:%M:%S UTC")${RESET}"
    echo ""

    # ── Gateway ──
    echo -e "${BOLD}Gateway${RESET}"
    if $gateway_running; then
      echo -e "  ${PASS} Running (PID ${gateway_pid})"
      [[ -n "$gateway_uptime" ]] && echo -e "  ${INFO} Process uptime: ${gateway_uptime}"
    else
      echo -e "  ${FAIL} Not running"
    fi
    if [[ "$gateway_rpc" == "ok" ]]; then
      echo -e "  ${PASS} RPC responding (port ${GATEWAY_PORT})"
    elif [[ "$gateway_rpc" == "unreachable" ]]; then
      echo -e "  ${FAIL} RPC not responding (port ${GATEWAY_PORT})"
    else
      echo -e "  ${INFO} RPC status unknown"
    fi
    echo ""

    # ── Watchdog ──
    echo -e "${BOLD}Watchdog${RESET}"
    if $watchdog_running; then
      echo -e "  ${PASS} Daemon running (PID ${watchdog_pid})"
    elif $watchdog_cron; then
      echo -e "  ${PASS} Active via cron"
    else
      echo -e "  ${WARN} Not running (no daemon or cron)"
    fi
    if [[ -n "$watchdog_last_check" ]]; then
      echo -e "  ${INFO} Last check: ${watchdog_last_check}"
    fi
    if (( watchdog_restarts > 0 )); then
      echo -e "  ${WARN} ${watchdog_restarts} restart(s) in log"
    fi
    echo ""

    # ── Backups ──
    echo -e "${BOLD}Backups${RESET}"
    if (( backup_count > 0 )); then
      echo -e "  ${PASS} ${backup_count} backup(s) in ${BACKUP_DIR}"
      echo -e "  ${INFO} Latest: ${backup_last} (${backup_last_size}, ${backup_last_age})"
    else
      echo -e "  ${WARN} No backups found"
    fi
    echo ""

    # ── Resources ──
    echo -e "${BOLD}Resources${RESET}"
    # RAM
    mem_icon="${PASS}"
    (( mem_available_kb < 500000 )) && mem_icon="${WARN}"
    (( mem_available_kb < 200000 )) && mem_icon="${FAIL}"
    echo -e "  ${mem_icon} RAM: ${mem_pct}% — $(( mem_available_kb / 1024 )) MB available / $(( mem_total_kb / 1024 )) MB"
    if (( swap_total_kb > 0 )); then
      echo -e "  ${INFO} Swap: $(( swap_used_kb / 1024 )) MB / $(( swap_total_kb / 1024 )) MB"
    fi
    # Storage
    disk_icon="${PASS}"
    (( storage_avail_kb < 5242880 )) && disk_icon="${WARN}"
    (( storage_avail_kb < 1048576 )) && disk_icon="${FAIL}"
    echo -e "  ${disk_icon} Disk: ${storage_pct}% — $(( storage_avail_kb / 1048576 )) GB available / $(( storage_total_kb / 1048576 )) GB"
    echo ""

    # ── Battery ──
    if [[ -n "$battery_pct" ]]; then
      echo -e "${BOLD}Battery${RESET}"
      bat_icon="${PASS}"
      [[ "$battery_plugged" == "UNPLUGGED" ]] && (( battery_pct < 30 )) && bat_icon="${WARN}"
      [[ "$battery_plugged" == "UNPLUGGED" ]] && (( battery_pct < 15 )) && bat_icon="${FAIL}"
      plugged_str=""
      [[ "$battery_plugged" != "UNPLUGGED" ]] && plugged_str=" ⚡"
      echo -e "  ${bat_icon} ${battery_pct}%${plugged_str} — ${battery_status}"
      [[ -n "$battery_temp" ]] && echo -e "  ${INFO} Temperature: ${battery_temp}°C"
      echo ""
    fi

    # ── System ──
    echo -e "${BOLD}System${RESET}"
    echo -e "  ${INFO} Load: ${load_1}"
    echo -e "  ${INFO} Uptime: ${uptime_human}"
    echo ""

    # ── Summary ──
    case "$overall" in
      ok)
        echo -e "${PASS} ${GREEN}All systems operational${RESET}"
        ;;
      warning)
        echo -e "${WARN} ${YELLOW}Warnings:${RESET}"
        for w in "${warnings[@]}"; do echo -e "  ${WARN} $w"; done
        ;;
      critical)
        echo -e "${FAIL} ${RED}Critical:${RESET}"
        for p in "${problems[@]}"; do echo -e "  ${FAIL} $p"; done
        if [[ ${#warnings[@]} -gt 0 ]]; then
          echo -e "${WARN} ${YELLOW}Warnings:${RESET}"
          for w in "${warnings[@]}"; do echo -e "  ${WARN} $w"; done
        fi
        ;;
    esac
    ;;
esac

# Exit code reflects status
case "$overall" in
  ok) exit 0 ;;
  warning) exit 1 ;;
  critical) exit 2 ;;
esac
