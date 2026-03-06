#!/data/data/com.termux/files/usr/bin/bash
# Shared utilities for Android Agent Toolkit

# Colors (disabled if not a terminal or NO_COLOR is set)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

# Status indicators
PASS="${GREEN}✓${RESET}"
WARN="${YELLOW}⚠${RESET}"
FAIL="${RED}✗${RESET}"
INFO="${BLUE}ℹ${RESET}"

# Find the node binary (openclaw-android installs its own)
find_node() {
  local candidates=(
    "$HOME/.openclaw-android/node/bin/node"
    "$(which node 2>/dev/null)"
  )
  for n in "${candidates[@]}"; do
    if [[ -x "$n" ]]; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

# Find the openclaw binary
find_openclaw() {
  local candidates=(
    "$(which openclaw 2>/dev/null)"
    "/data/data/com.termux/files/usr/bin/openclaw"
  )
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# Parse /proc/meminfo value in kB
meminfo_kb() {
  local key="$1"
  awk -v k="$key:" '$1 == k { print $2 }' /proc/meminfo
}

# Human-readable bytes
human_bytes() {
  local bytes="$1"
  if (( bytes >= 1073741824 )); then
    echo "$(( bytes / 1073741824 )).$((( bytes % 1073741824 ) * 10 / 1073741824 )) GB"
  elif (( bytes >= 1048576 )); then
    echo "$(( bytes / 1048576 )) MB"
  elif (( bytes >= 1024 )); then
    echo "$(( bytes / 1024 )) KB"
  else
    echo "${bytes} B"
  fi
}
