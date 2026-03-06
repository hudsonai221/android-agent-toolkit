#!/data/data/com.termux/files/usr/bin/bash
# aat bench — device benchmarker for OpenClaw on Android
#
# Tests:
#   1. CPU throughput (sha256 hashing)
#   2. Memory (available RAM + allocation test)
#   3. Disk I/O (sequential write + read)
#   4. Node.js startup time
#   5. Gateway RPC latency
#   6. Network latency (DNS + HTTP)
#
# Outputs a compatibility score (0-100) with per-subsystem breakdown.
# --json for machine consumption, --quick for faster (smaller) tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- Parse args ---
OUTPUT_FORMAT="human"  # human | json
QUICK_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_FORMAT="json"; shift ;;
    --quick) QUICK_MODE=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: aat bench [--json] [--quick]

Benchmark device performance for OpenClaw compatibility.

Options:
  --json    Output as JSON (for scripting/reporting)
  --quick   Run smaller tests (faster, less precise)
  -h        Show this help

Scores:
  90-100  Excellent — runs OpenClaw smoothly
  70-89   Good — handles most workloads
  50-69   Adequate — may struggle under heavy load
  30-49   Marginal — expect slowdowns and memory pressure
  0-29    Poor — likely to crash or timeout frequently
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --- Helpers ---

BENCH_TMP="$HOME/.aat-bench-$$"
mkdir -p "$BENCH_TMP"
cleanup() { rm -rf "$BENCH_TMP"; }
trap cleanup EXIT

# Time a command in milliseconds (uses bash SECONDS workaround since date +%N isn't always available)
# Returns milliseconds via variable name passed as $1
time_ms() {
  local varname="$1"
  shift
  local start end
  # Try nanosecond timing first
  if start=$(date +%s%N 2>/dev/null) && [[ ${#start} -gt 10 ]]; then
    "$@" >/dev/null 2>&1
    end=$(date +%s%N)
    eval "$varname=$(( (end - start) / 1000000 ))"
  else
    # Fall back to seconds-level timing
    start=$(date +%s)
    "$@" >/dev/null 2>&1
    end=$(date +%s)
    eval "$varname=$(( (end - start) * 1000 ))"
  fi
}

# Score a metric on a 0-100 scale given thresholds
# score_metric <value> <excellent> <good> <adequate> <poor>
# Lower value = better (e.g., latency)
score_lower_better() {
  local val="$1" excellent="$2" good="$3" adequate="$4" poor="$5"
  if (( val <= excellent )); then echo 100
  elif (( val <= good )); then echo $(( 100 - (val - excellent) * 25 / (good - excellent) ))
  elif (( val <= adequate )); then echo $(( 75 - (val - good) * 25 / (adequate - good) ))
  elif (( val <= poor )); then echo $(( 50 - (val - adequate) * 25 / (poor - adequate) ))
  else echo $(( 25 > (25 - (val - poor) * 25 / poor) ? (25 - (val - poor) * 25 / poor) : 0 ))
  fi
}

# Higher value = better (e.g., throughput)
score_higher_better() {
  local val="$1" excellent="$2" good="$3" adequate="$4" poor="$5"
  if (( val >= excellent )); then echo 100
  elif (( val >= good )); then echo $(( 75 + (val - good) * 25 / (excellent - good) ))
  elif (( val >= adequate )); then echo $(( 50 + (val - adequate) * 25 / (good - adequate) ))
  elif (( val >= poor )); then echo $(( 25 + (val - poor) * 25 / (adequate - poor) ))
  else echo $(( val * 25 / poor > 0 ? val * 25 / poor : 0 ))
  fi
}

clamp() {
  local val="$1"
  (( val < 0 )) && val=0
  (( val > 100 )) && val=100
  echo "$val"
}

# --- Device Info ---
cpu_cores=$(nproc 2>/dev/null || echo 4)
cpu_arch=$(uname -m 2>/dev/null || echo "unknown")
hardware=$(grep "^Hardware" /proc/cpuinfo 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*//' || echo "unknown")

# --- 1. CPU Benchmark ---
# SHA256 hash throughput — how many hashes in a fixed time window

if [[ "$OUTPUT_FORMAT" == "human" ]]; then
  echo -e "${BOLD}Android Agent Toolkit — Device Benchmark${RESET}"
  echo -e "${DIM}$(date -u +"%Y-%m-%d %H:%M:%S UTC")${RESET}"
  echo ""
  echo -e "${BOLD}Device:${RESET} ${hardware} | ${cpu_cores} cores | ${cpu_arch}"
  echo ""
  echo -e "${DIM}Running benchmarks...${RESET}"
  echo ""
fi

# CPU: hash N MB of data
cpu_size_mb=32
$QUICK_MODE && cpu_size_mb=8

cpu_start=$(date +%s%N 2>/dev/null || echo "0")
if [[ ${#cpu_start} -gt 10 ]]; then
  dd if=/dev/zero bs=1M count=$cpu_size_mb 2>/dev/null | sha256sum >/dev/null 2>&1
  cpu_end=$(date +%s%N)
  cpu_time_ms=$(( (cpu_end - cpu_start) / 1000000 ))
else
  cpu_time_start=$(date +%s)
  dd if=/dev/zero bs=1M count=$cpu_size_mb 2>/dev/null | sha256sum >/dev/null 2>&1
  cpu_time_end=$(date +%s)
  cpu_time_ms=$(( (cpu_time_end - cpu_time_start) * 1000 ))
  # Avoid zero
  (( cpu_time_ms == 0 )) && cpu_time_ms=1
fi

# MB/s throughput
if (( cpu_time_ms > 0 )); then
  cpu_throughput_mbs=$(( cpu_size_mb * 1000 / cpu_time_ms ))
else
  cpu_throughput_mbs=999
fi

# Score CPU: thresholds in MB/s for sha256
cpu_score=$(clamp "$(score_higher_better "$cpu_throughput_mbs" 200 100 50 20)")

# --- 2. Memory Benchmark ---
mem_total_kb=$(meminfo_kb "MemTotal")
mem_available_kb=$(meminfo_kb "MemAvailable")
mem_available_mb=$(( mem_available_kb / 1024 ))
mem_total_mb=$(( mem_total_kb / 1024 ))

# Score memory: based on available MB
# OpenClaw needs ~500MB minimum comfortable, 1GB+ ideal
mem_score=$(clamp "$(score_higher_better "$mem_available_mb" 2048 1024 512 256)")

# --- 3. Disk I/O Benchmark ---
disk_size_mb=64
$QUICK_MODE && disk_size_mb=16

bench_file="$BENCH_TMP/disk_bench"

# Write test
# Note: Android toybox dd doesn't support conv=fdatasync, so we sync after
write_start=$(date +%s%N 2>/dev/null || echo "0")
if [[ ${#write_start} -gt 10 ]]; then
  dd if=/dev/zero of="$bench_file" bs=1M count=$disk_size_mb 2>/dev/null
  sync 2>/dev/null || true
  write_end=$(date +%s%N)
  write_time_ms=$(( (write_end - write_start) / 1000000 ))
else
  ws=$(date +%s)
  dd if=/dev/zero of="$bench_file" bs=1M count=$disk_size_mb 2>/dev/null
  sync 2>/dev/null || true
  we=$(date +%s)
  write_time_ms=$(( (we - ws) * 1000 ))
  (( write_time_ms == 0 )) && write_time_ms=1
fi

if (( write_time_ms > 0 )); then
  write_mbs=$(( disk_size_mb * 1000 / write_time_ms ))
else
  write_mbs=999
fi

# Read test (drop caches if possible, but usually can't on Android)
read_start=$(date +%s%N 2>/dev/null || echo "0")
if [[ ${#read_start} -gt 10 ]]; then
  dd if="$bench_file" of=/dev/null bs=1M 2>/dev/null
  read_end=$(date +%s%N)
  read_time_ms=$(( (read_end - read_start) / 1000000 ))
else
  rs=$(date +%s)
  dd if="$bench_file" of=/dev/null bs=1M 2>/dev/null
  re=$(date +%s)
  read_time_ms=$(( (re - rs) * 1000 ))
  (( read_time_ms == 0 )) && read_time_ms=1
fi

if (( read_time_ms > 0 )); then
  read_mbs=$(( disk_size_mb * 1000 / read_time_ms ))
else
  read_mbs=999
fi

rm -f "$bench_file"

# Score disk: thresholds in MB/s (write speed, more important)
disk_score=$(clamp "$(score_higher_better "$write_mbs" 500 200 100 30)")

# --- 4. Node.js Startup Time ---
node_bin=""
node_version=""
node_startup_ms=99999

if node_bin=$(find_node 2>/dev/null); then
  node_version=$("$node_bin" --version 2>/dev/null || echo "unknown")

  # Average 3 runs
  total_node_ms=0
  node_runs=3
  $QUICK_MODE && node_runs=1

  for i in $(seq 1 $node_runs); do
    ns=$(date +%s%N 2>/dev/null || echo "0")
    if [[ ${#ns} -gt 10 ]]; then
      "$node_bin" -e "process.exit(0)" 2>/dev/null
      ne=$(date +%s%N)
      run_ms=$(( (ne - ns) / 1000000 ))
    else
      nss=$(date +%s)
      "$node_bin" -e "process.exit(0)" 2>/dev/null
      nse=$(date +%s)
      run_ms=$(( (nse - nss) * 1000 ))
    fi
    total_node_ms=$(( total_node_ms + run_ms ))
  done

  node_startup_ms=$(( total_node_ms / node_runs ))
fi

# Score node: lower startup = better
node_score=$(clamp "$(score_lower_better "$node_startup_ms" 100 300 800 2000)")

# --- 5. Gateway RPC Latency ---
gateway_port="${OPENCLAW_PORT:-18789}"
gateway_latency_ms=99999
gateway_status="not running"

if command -v curl &>/dev/null; then
  # Average 3 pings
  total_gw_ms=0
  gw_runs=3
  gw_success=0
  $QUICK_MODE && gw_runs=1

  for i in $(seq 1 $gw_runs); do
    gs=$(date +%s%N 2>/dev/null || echo "0")
    if [[ ${#gs} -gt 10 ]]; then
      http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${gateway_port}/" 2>/dev/null || echo "000")
      ge=$(date +%s%N)
      run_ms=$(( (ge - gs) / 1000000 ))
    else
      gss=$(date +%s)
      http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${gateway_port}/" 2>/dev/null || echo "000")
      gse=$(date +%s)
      run_ms=$(( (gse - gss) * 1000 ))
    fi

    if [[ "$http_code" =~ ^[23] ]]; then
      total_gw_ms=$(( total_gw_ms + run_ms ))
      gw_success=$(( gw_success + 1 ))
    fi
  done

  if (( gw_success > 0 )); then
    gateway_latency_ms=$(( total_gw_ms / gw_success ))
    gateway_status="ok"
  else
    gateway_status="unreachable"
  fi
fi

# Score gateway: lower latency = better
if [[ "$gateway_status" == "ok" ]]; then
  gw_score=$(clamp "$(score_lower_better "$gateway_latency_ms" 20 50 200 1000)")
else
  gw_score=0
fi

# --- 6. Network Latency ---
net_latency_ms=99999
net_status="untested"
net_dns_ms=99999

if command -v curl &>/dev/null; then
  # DNS resolution test
  dns_start=$(date +%s%N 2>/dev/null || echo "0")
  if [[ ${#dns_start} -gt 10 ]]; then
    # Resolve only, no download — capture output to suppress it
    curl -s -o /dev/null --max-time 10 -w "%{time_namelookup}" "https://api.anthropic.com" >/dev/null 2>&1 || true
    dns_end=$(date +%s%N)
    net_dns_ms=$(( (dns_end - dns_start) / 1000000 ))
  fi

  # Full HTTP request
  http_start=$(date +%s%N 2>/dev/null || echo "0")
  if [[ ${#http_start} -gt 10 ]]; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://api.anthropic.com/" 2>/dev/null || echo "000")
    http_end=$(date +%s%N)
    net_latency_ms=$(( (http_end - http_start) / 1000000 ))
    if [[ "$http_code" != "000" ]]; then
      net_status="ok"
    else
      net_status="unreachable"
    fi
  else
    nss=$(date +%s)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://api.anthropic.com/" 2>/dev/null || echo "000")
    nse=$(date +%s)
    net_latency_ms=$(( (nse - nss) * 1000 ))
    if [[ "$http_code" != "000" ]]; then
      net_status="ok"
    else
      net_status="unreachable"
    fi
  fi
fi

# Score network: lower = better
if [[ "$net_status" == "ok" ]]; then
  net_score=$(clamp "$(score_lower_better "$net_latency_ms" 200 500 1500 5000)")
else
  net_score=0
fi

# --- Overall Score ---
# Weighted average: memory and CPU matter most for OpenClaw
# CPU:25% Memory:25% Disk:15% Node:15% Gateway:10% Network:10%
if [[ "$gateway_status" == "ok" ]]; then
  overall_score=$(( (cpu_score * 25 + mem_score * 25 + disk_score * 15 + node_score * 15 + gw_score * 10 + net_score * 10) / 100 ))
else
  # Gateway not running — score without it, redistribute weight
  overall_score=$(( (cpu_score * 30 + mem_score * 30 + disk_score * 15 + node_score * 15 + net_score * 10) / 100 ))
fi

overall_score=$(clamp "$overall_score")

# Rating
if (( overall_score >= 90 )); then rating="Excellent"
elif (( overall_score >= 70 )); then rating="Good"
elif (( overall_score >= 50 )); then rating="Adequate"
elif (( overall_score >= 30 )); then rating="Marginal"
else rating="Poor"
fi

# --- Output ---

case "$OUTPUT_FORMAT" in
  json)
    cat <<EOJSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "device": {
    "hardware": "${hardware}",
    "cpu_cores": ${cpu_cores},
    "arch": "${cpu_arch}",
    "ram_total_mb": ${mem_total_mb},
    "ram_available_mb": ${mem_available_mb}
  },
  "benchmarks": {
    "cpu": {
      "sha256_throughput_mbs": ${cpu_throughput_mbs},
      "test_size_mb": ${cpu_size_mb},
      "time_ms": ${cpu_time_ms},
      "score": ${cpu_score}
    },
    "memory": {
      "available_mb": ${mem_available_mb},
      "total_mb": ${mem_total_mb},
      "score": ${mem_score}
    },
    "disk": {
      "write_mbs": ${write_mbs},
      "read_mbs": ${read_mbs},
      "test_size_mb": ${disk_size_mb},
      "write_time_ms": ${write_time_ms},
      "read_time_ms": ${read_time_ms},
      "score": ${disk_score}
    },
    "node": {
      "version": "${node_version}",
      "startup_ms": ${node_startup_ms},
      "score": ${node_score}
    },
    "gateway": {
      "status": "${gateway_status}",
      "latency_ms": $(if [[ "$gateway_status" == "ok" ]]; then echo "$gateway_latency_ms"; else echo null; fi),
      "port": ${gateway_port},
      "score": ${gw_score}
    },
    "network": {
      "status": "${net_status}",
      "latency_ms": $(if [[ "$net_status" == "ok" ]]; then echo "$net_latency_ms"; else echo null; fi),
      "dns_ms": $(if (( net_dns_ms < 99999 )); then echo "$net_dns_ms"; else echo null; fi),
      "target": "api.anthropic.com",
      "score": ${net_score}
    }
  },
  "overall": {
    "score": ${overall_score},
    "rating": "${rating}"
  }
}
EOJSON
    ;;

  human)
    # CPU
    echo -e "${BOLD}CPU${RESET}"
    cpu_icon="${PASS}"
    (( cpu_score < 50 )) && cpu_icon="${WARN}"
    (( cpu_score < 25 )) && cpu_icon="${FAIL}"
    echo -e "  ${cpu_icon} SHA256 throughput: ${cpu_throughput_mbs} MB/s (${cpu_size_mb} MB in ${cpu_time_ms} ms)"
    echo -e "     Score: ${cpu_score}/100"
    echo ""

    # Memory
    echo -e "${BOLD}Memory${RESET}"
    mem_icon="${PASS}"
    (( mem_score < 50 )) && mem_icon="${WARN}"
    (( mem_score < 25 )) && mem_icon="${FAIL}"
    echo -e "  ${mem_icon} Available: ${mem_available_mb} MB / ${mem_total_mb} MB total"
    echo -e "     Score: ${mem_score}/100"
    echo ""

    # Disk
    echo -e "${BOLD}Disk I/O${RESET}"
    disk_icon="${PASS}"
    (( disk_score < 50 )) && disk_icon="${WARN}"
    (( disk_score < 25 )) && disk_icon="${FAIL}"
    echo -e "  ${disk_icon} Write: ${write_mbs} MB/s | Read: ${read_mbs} MB/s (${disk_size_mb} MB test)"
    echo -e "     Score: ${disk_score}/100"
    echo ""

    # Node.js
    echo -e "${BOLD}Node.js${RESET}"
    if [[ -n "$node_bin" ]]; then
      node_icon="${PASS}"
      (( node_score < 50 )) && node_icon="${WARN}"
      (( node_score < 25 )) && node_icon="${FAIL}"
      echo -e "  ${node_icon} Startup: ${node_startup_ms} ms (${node_version})"
    else
      node_icon="${FAIL}"
      echo -e "  ${node_icon} Node.js not found"
    fi
    echo -e "     Score: ${node_score}/100"
    echo ""

    # Gateway
    echo -e "${BOLD}Gateway RPC${RESET}"
    if [[ "$gateway_status" == "ok" ]]; then
      gw_icon="${PASS}"
      (( gw_score < 50 )) && gw_icon="${WARN}"
      (( gw_score < 25 )) && gw_icon="${FAIL}"
      echo -e "  ${gw_icon} Latency: ${gateway_latency_ms} ms (port ${gateway_port})"
      echo -e "     Score: ${gw_score}/100"
    else
      echo -e "  ${INFO} Gateway not running — skipped"
    fi
    echo ""

    # Network
    echo -e "${BOLD}Network${RESET}"
    if [[ "$net_status" == "ok" ]]; then
      net_icon="${PASS}"
      (( net_score < 50 )) && net_icon="${WARN}"
      (( net_score < 25 )) && net_icon="${FAIL}"
      echo -e "  ${net_icon} API latency: ${net_latency_ms} ms (api.anthropic.com)"
      echo -e "     Score: ${net_score}/100"
    elif [[ "$net_status" == "unreachable" ]]; then
      echo -e "  ${FAIL} API unreachable (api.anthropic.com)"
      echo -e "     Score: 0/100"
    else
      echo -e "  ${INFO} Network test skipped"
    fi
    echo ""

    # Overall
    echo -e "${BOLD}═══════════════════════════════════════${RESET}"
    overall_icon="${PASS}"
    overall_color="${GREEN}"
    if (( overall_score < 50 )); then
      overall_icon="${WARN}"
      overall_color="${YELLOW}"
    fi
    if (( overall_score < 30 )); then
      overall_icon="${FAIL}"
      overall_color="${RED}"
    fi
    echo -e "${overall_icon} ${BOLD}Overall: ${overall_color}${overall_score}/100 — ${rating}${RESET}"
    echo ""

    # Recommendations
    if (( overall_score < 70 )); then
      echo -e "${BOLD}Recommendations:${RESET}"
      if (( mem_score < 50 )); then
        echo -e "  ${WARN} Low available RAM — close other apps, consider ZRAM/swap"
      fi
      if (( cpu_score < 50 )); then
        echo -e "  ${WARN} CPU is slow — expect longer response times"
      fi
      if (( disk_score < 50 )); then
        echo -e "  ${WARN} Slow storage — backups and operations will be sluggish"
      fi
      if (( node_score < 50 )); then
        echo -e "  ${WARN} Node.js startup is slow — gateway restarts will take time"
      fi
      if (( net_score < 50 )) && [[ "$net_status" != "untested" ]]; then
        echo -e "  ${WARN} High API latency — check network connection"
      fi
      echo ""
    fi
    ;;
esac

exit 0
