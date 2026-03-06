#!/data/data/com.termux/files/usr/bin/bash
# aat health — comprehensive health check for OpenClaw on Android
#
# Checks:
#   1. Gateway process running
#   2. Gateway RPC responding
#   3. Memory (RAM) usage and availability
#   4. Storage usage
#   5. Battery status (if termux-api available)
#   6. System load
#   7. Uptime
#
# Outputs: human-readable report, --json for machine consumption, --brief for one-liner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- Parse args ---
OUTPUT_FORMAT="human"  # human | json | brief
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_FORMAT="json"; shift ;;
    --brief) OUTPUT_FORMAT="brief"; shift ;;
    -h|--help)
      echo "Usage: aat health [--json|--brief]"
      echo ""
      echo "Options:"
      echo "  --json    Output as JSON (for scripting)"
      echo "  --brief   One-line summary"
      echo "  -h        Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --- Collect data ---

# Track overall status: ok, warning, critical
overall="ok"
problems=()
warnings=()

# 1. Gateway process
gateway_pid=""
gateway_running=false
if pgrep -f "openclaw" > /dev/null 2>&1; then
  gateway_pid=$(pgrep -f "openclaw" | head -1)
  gateway_running=true
fi

# 2. Gateway RPC probe
gateway_rpc="unknown"
gateway_port="${OPENCLAW_PORT:-18789}"
if command -v curl &>/dev/null; then
  if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${gateway_port}/" 2>/dev/null | grep -q "^[23]"; then
    gateway_rpc="ok"
  else
    gateway_rpc="unreachable"
  fi
fi

if ! $gateway_running; then
  overall="critical"
  problems+=("Gateway process not found")
elif [[ "$gateway_rpc" == "unreachable" ]]; then
  overall="critical"
  problems+=("Gateway RPC not responding on port ${gateway_port}")
fi

# 3. Memory
mem_total_kb=$(meminfo_kb "MemTotal")
mem_available_kb=$(meminfo_kb "MemAvailable")
mem_free_kb=$(meminfo_kb "MemFree")
mem_buffers_kb=$(meminfo_kb "Buffers")
mem_cached_kb=$(meminfo_kb "Cached")
mem_used_kb=$(( mem_total_kb - mem_available_kb ))

swap_total_kb=$(meminfo_kb "SwapTotal")
swap_free_kb=$(meminfo_kb "SwapFree")
swap_used_kb=$(( swap_total_kb - swap_free_kb ))

mem_pct=$(( mem_used_kb * 100 / mem_total_kb ))
if (( mem_available_kb < 200000 )); then  # < 200MB available
  overall="critical"
  problems+=("RAM critically low: $(human_bytes $((mem_available_kb * 1024))) available")
elif (( mem_available_kb < 500000 )); then  # < 500MB available
  [[ "$overall" == "ok" ]] && overall="warning"
  warnings+=("RAM low: $(human_bytes $((mem_available_kb * 1024))) available")
fi

# 4. Storage
storage_line=$(df -k /data 2>/dev/null | tail -1)
storage_total_kb=$(echo "$storage_line" | awk '{print $2}')
storage_used_kb=$(echo "$storage_line" | awk '{print $3}')
storage_avail_kb=$(echo "$storage_line" | awk '{print $4}')
storage_pct=$(echo "$storage_line" | awk '{print $5}' | tr -d '%')

if (( storage_avail_kb < 1048576 )); then  # < 1GB available
  overall="critical"
  problems+=("Storage critically low: $(human_bytes $((storage_avail_kb * 1024))) available")
elif (( storage_avail_kb < 5242880 )); then  # < 5GB available
  [[ "$overall" == "ok" ]] && overall="warning"
  warnings+=("Storage getting low: $(human_bytes $((storage_avail_kb * 1024))) available")
fi

# 5. Battery (optional — needs termux-api)
battery_pct=""
battery_status=""
battery_temp=""
battery_plugged=""
battery_health=""
if command -v termux-battery-status &>/dev/null; then
  battery_json=$(termux-battery-status 2>/dev/null || echo "{}")
  if command -v jq &>/dev/null && [[ -n "$battery_json" ]]; then
    battery_pct=$(echo "$battery_json" | jq -r '.percentage // empty' 2>/dev/null)
    battery_status=$(echo "$battery_json" | jq -r '.status // empty' 2>/dev/null)
    battery_temp=$(echo "$battery_json" | jq -r '.temperature // empty' 2>/dev/null)
    battery_plugged=$(echo "$battery_json" | jq -r '.plugged // empty' 2>/dev/null)
    battery_health=$(echo "$battery_json" | jq -r '.health // empty' 2>/dev/null)
  fi

  if [[ -n "$battery_temp" ]] && (( $(echo "$battery_temp > 45" | bc 2>/dev/null || echo 0) )); then
    overall="critical"
    problems+=("Battery temperature critical: ${battery_temp}°C")
  elif [[ -n "$battery_temp" ]] && (( $(echo "$battery_temp > 38" | bc 2>/dev/null || echo 0) )); then
    [[ "$overall" == "ok" ]] && overall="warning"
    warnings+=("Battery temperature elevated: ${battery_temp}°C")
  fi

  if [[ -n "$battery_pct" ]] && [[ "$battery_plugged" == "UNPLUGGED" ]] && (( battery_pct < 15 )); then
    overall="critical"
    problems+=("Battery critically low: ${battery_pct}% (unplugged)")
  elif [[ -n "$battery_pct" ]] && [[ "$battery_plugged" == "UNPLUGGED" ]] && (( battery_pct < 30 )); then
    [[ "$overall" == "ok" ]] && overall="warning"
    warnings+=("Battery low: ${battery_pct}% (unplugged)")
  fi
fi

# 6. System load
# /proc/loadavg may be restricted on Android
load_1="n/a"
load_5="n/a"
load_15="n/a"
load_available=false
if loadavg=$(cat /proc/loadavg 2>/dev/null); then
  load_1=$(echo "$loadavg" | awk '{print $1}')
  load_5=$(echo "$loadavg" | awk '{print $2}')
  load_15=$(echo "$loadavg" | awk '{print $3}')
  load_available=true
fi

cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 4)
if $load_available; then
  load_1_int=$(echo "$load_1" | cut -d. -f1)
  if (( load_1_int > cpu_cores * 3 )); then
    [[ "$overall" == "ok" ]] && overall="warning"
    warnings+=("System load very high: ${load_1}")
  fi
fi

# 7. Uptime
# /proc/uptime may be restricted; fall back to 'uptime' command output parsing
uptime_seconds=0
uptime_human="unknown"
if uptime_raw=$(cat /proc/uptime 2>/dev/null); then
  uptime_seconds=$(echo "$uptime_raw" | awk '{print int($1)}')
  uptime_days=$(( uptime_seconds / 86400 ))
  uptime_hours=$(( (uptime_seconds % 86400) / 3600 ))
  uptime_mins=$(( (uptime_seconds % 3600) / 60 ))
  uptime_human="${uptime_days}d ${uptime_hours}h ${uptime_mins}m"
elif uptime_str=$(uptime 2>/dev/null); then
  # Parse "up X days, H:MM" style output
  uptime_human=$(echo "$uptime_str" | sed 's/.*up //' | sed 's/,.*//')
fi

# --- Output ---

case "$OUTPUT_FORMAT" in
  json)
    # Build JSON output
    cat <<EOJSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "overall": "${overall}",
  "gateway": {
    "running": ${gateway_running},
    "pid": ${gateway_pid:-null},
    "rpc": "${gateway_rpc}",
    "port": ${gateway_port}
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
    "plugged": $(if [[ -n "$battery_plugged" ]]; then echo "\"$battery_plugged\""; else echo null; fi),
    "health": $(if [[ -n "$battery_health" ]]; then echo "\"$battery_health\""; else echo null; fi)
  },
  "system": {
    "load_1m": $(if $load_available; then echo "${load_1}"; else echo null; fi),
    "load_5m": $(if $load_available; then echo "${load_5}"; else echo null; fi),
    "load_15m": $(if $load_available; then echo "${load_15}"; else echo null; fi),
    "cpu_cores": ${cpu_cores},
    "uptime_seconds": $(if (( uptime_seconds > 0 )); then echo "${uptime_seconds}"; else echo null; fi)
  },
  "problems": [$(if [[ ${#problems[@]} -gt 0 ]]; then printf '"%s",' "${problems[@]}" | sed 's/,$//'; fi)],
  "warnings": [$(if [[ ${#warnings[@]} -gt 0 ]]; then printf '"%s",' "${warnings[@]}" | sed 's/,$//'; fi)]
}
EOJSON
    ;;

  brief)
    # One-line summary
    status_icon="✓"
    [[ "$overall" == "warning" ]] && status_icon="⚠"
    [[ "$overall" == "critical" ]] && status_icon="✗"

    gw_status="gw:up"
    $gateway_running || gw_status="gw:DOWN"

    battery_brief=""
    [[ -n "$battery_pct" ]] && battery_brief=" bat:${battery_pct}%"

    echo "${status_icon} ${overall} | ${gw_status} rpc:${gateway_rpc} | ram:${mem_pct}% ($(( mem_available_kb / 1024 ))MB free) | disk:${storage_pct}% ($(( storage_avail_kb / 1048576 ))GB free)${battery_brief} | load:${load_1} | up:${uptime_human}"
    ;;

  human)
    echo -e "${BOLD}Android Agent Toolkit — Health Check${RESET}"
    echo -e "${DIM}$(date -u +"%Y-%m-%d %H:%M:%S UTC")${RESET}"
    echo ""

    # Gateway
    echo -e "${BOLD}Gateway${RESET}"
    if $gateway_running; then
      echo -e "  ${PASS} Process running (PID ${gateway_pid})"
    else
      echo -e "  ${FAIL} Process not found"
    fi
    if [[ "$gateway_rpc" == "ok" ]]; then
      echo -e "  ${PASS} RPC responding on port ${gateway_port}"
    elif [[ "$gateway_rpc" == "unreachable" ]]; then
      echo -e "  ${FAIL} RPC not responding on port ${gateway_port}"
    else
      echo -e "  ${INFO} RPC status unknown"
    fi
    echo ""

    # Memory
    echo -e "${BOLD}Memory${RESET}"
    mem_icon="${PASS}"
    (( mem_available_kb < 500000 )) && mem_icon="${WARN}"
    (( mem_available_kb < 200000 )) && mem_icon="${FAIL}"
    echo -e "  ${mem_icon} RAM: ${mem_pct}% used — $(( mem_available_kb / 1024 )) MB available / $(( mem_total_kb / 1024 )) MB total"
    if (( swap_total_kb > 0 )); then
      echo -e "  ${INFO} Swap: $(( swap_used_kb / 1024 )) MB used / $(( swap_total_kb / 1024 )) MB total"
    fi
    echo ""

    # Storage
    echo -e "${BOLD}Storage${RESET}"
    disk_icon="${PASS}"
    (( storage_avail_kb < 5242880 )) && disk_icon="${WARN}"
    (( storage_avail_kb < 1048576 )) && disk_icon="${FAIL}"
    echo -e "  ${disk_icon} Disk: ${storage_pct}% used — $(( storage_avail_kb / 1048576 )) GB available / $(( storage_total_kb / 1048576 )) GB total"
    echo ""

    # Battery
    if [[ -n "$battery_pct" ]]; then
      echo -e "${BOLD}Battery${RESET}"
      bat_icon="${PASS}"
      [[ "$battery_plugged" == "UNPLUGGED" ]] && (( battery_pct < 30 )) && bat_icon="${WARN}"
      [[ "$battery_plugged" == "UNPLUGGED" ]] && (( battery_pct < 15 )) && bat_icon="${FAIL}"
      plugged_str=""
      [[ "$battery_plugged" != "UNPLUGGED" ]] && plugged_str=" (plugged in)"
      echo -e "  ${bat_icon} Level: ${battery_pct}%${plugged_str} — ${battery_status}"

      temp_icon="${PASS}"
      if [[ -n "$battery_temp" ]]; then
        (( $(echo "$battery_temp > 38" | bc 2>/dev/null || echo 0) )) && temp_icon="${WARN}"
        (( $(echo "$battery_temp > 45" | bc 2>/dev/null || echo 0) )) && temp_icon="${FAIL}"
        echo -e "  ${temp_icon} Temperature: ${battery_temp}°C"
      fi
      [[ -n "$battery_health" ]] && echo -e "  ${INFO} Health: ${battery_health}"
      echo ""
    fi

    # System
    echo -e "${BOLD}System${RESET}"
    echo -e "  ${INFO} Load: ${load_1} / ${load_5} / ${load_15} (${cpu_cores} cores)"
    echo -e "  ${INFO} Uptime: ${uptime_human}"
    echo ""

    # Summary
    case "$overall" in
      ok)
        echo -e "${PASS} ${GREEN}All checks passed${RESET}"
        ;;
      warning)
        echo -e "${WARN} ${YELLOW}Warnings:${RESET}"
        for w in "${warnings[@]}"; do
          echo -e "  ${WARN} $w"
        done
        ;;
      critical)
        echo -e "${FAIL} ${RED}Critical issues:${RESET}"
        for p in "${problems[@]}"; do
          echo -e "  ${FAIL} $p"
        done
        if [[ ${#warnings[@]} -gt 0 ]]; then
          echo -e "${WARN} ${YELLOW}Warnings:${RESET}"
          for w in "${warnings[@]}"; do
            echo -e "  ${WARN} $w"
          done
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
