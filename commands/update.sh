#!/data/data/com.termux/files/usr/bin/bash
# aat update — safe OpenClaw update wrapper
#
# Workflow:
#   1. Check for available updates (npm view)
#   2. Create pre-update backup (aat backup)
#   3. Stop gateway
#   4. Run openclaw-android platform update
#   5. Start gateway + verify RPC
#   6. Report results (rollback info if failed)
#
# Usage: aat update [--check] [--force] [--skip-backup] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- Config ---
AAT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATEWAY_PORT="${OPENCLAW_PORT:-18789}"
OA_PLATFORM_UPDATE="$HOME/.openclaw-android/platforms/openclaw/update.sh"
OA_PLATFORM_VERIFY="$HOME/.openclaw-android/platforms/openclaw/verify.sh"
BACKUP_DIR="$HOME/backups"
MAX_STARTUP_WAIT=60  # seconds to wait for gateway RPC after restart

# On Termux, npm's shebang (/usr/bin/env) may not resolve.
# Use node to run npm directly as a workaround.
_npm() {
  local npm_bin
  npm_bin=$(which npm 2>/dev/null) || npm_bin="$HOME/.openclaw-android/node/bin/npm"
  local node_bin
  node_bin=$(find_node) || { echo "node not found" >&2; return 1; }
  "$node_bin" "$npm_bin" "$@"
}

# --- Defaults ---
CHECK_ONLY=false
FORCE=false
SKIP_BACKUP=false
OUTPUT_FORMAT="human"  # human | json

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|-c)      CHECK_ONLY=true; shift ;;
    --force|-f)      FORCE=true; shift ;;
    --skip-backup)   SKIP_BACKUP=true; shift ;;
    --json)          OUTPUT_FORMAT="json"; shift ;;
    -h|--help)
      cat <<EOF
Usage: aat update [options]

Safely update OpenClaw with automatic backup and verification.

Steps:
  1. Check if a new version is available
  2. Create an essential backup (unless --skip-backup)
  3. Stop the gateway
  4. Run the openclaw-android platform updater
  5. Restart and verify the gateway
  6. Report results

Options:
  --check, -c     Only check for updates (don't install)
  --force, -f     Update even if already on latest version
  --skip-backup   Skip the pre-update backup
  --json          Output as JSON
  -h, --help      Show this help

Examples:
  aat update --check        # Check if an update is available
  aat update                # Full safe update
  aat update --force        # Re-run update even if on latest
  aat update --skip-backup  # Skip pre-update backup (faster)

Rollback:
  If the update fails, a backup is available in ~/backups/.
  Restore with: tar xzf ~/backups/aat-backup-TIMESTAMP.tar.gz
  Then restart: openclaw gateway restart

Requirements:
  - openclaw-android installer (~/.openclaw-android/)
EOF
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      echo "Run 'aat update --help' for usage." >&2
      exit 1
      ;;
  esac
done

# --- Helpers ---

log_step() {
  [[ "$OUTPUT_FORMAT" == "human" ]] && echo -e "\n${BOLD}$1${RESET}" || true
}

log_ok() {
  [[ "$OUTPUT_FORMAT" == "human" ]] && echo -e "  ${PASS} $1" || true
}

log_warn() {
  [[ "$OUTPUT_FORMAT" == "human" ]] && echo -e "  ${WARN} $1" || true
}

log_fail() {
  [[ "$OUTPUT_FORMAT" == "human" ]] && echo -e "  ${FAIL} $1" || true
}

log_info() {
  [[ "$OUTPUT_FORMAT" == "human" ]] && echo -e "  ${INFO} $1" || true
}

# Check if gateway RPC is responding
gateway_rpc_ok() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null) || true
  [[ "$code" =~ ^[23] ]]
}

# Wait for gateway RPC to come up
wait_for_gateway() {
  local timeout="$1"
  local elapsed=0
  local interval=3
  while (( elapsed < timeout )); do
    if gateway_rpc_ok; then
      return 0
    fi
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done
  return 1
}

# --- Pre-flight checks ---

# Verify openclaw-android is installed
if [[ ! -f "$OA_PLATFORM_UPDATE" ]]; then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo '{"status":"error","error":"openclaw-android not installed","detail":"Expected update script at '"$OA_PLATFORM_UPDATE"'"}'
  else
    log_fail "openclaw-android not installed"
    echo "  Expected: $OA_PLATFORM_UPDATE"
    echo "  Install from: https://github.com/AidanPark/openclaw-android"
  fi
  exit 1
fi

# --- Step 1: Check versions ---

log_step "Checking versions..."

current_ver=$(_npm list -g openclaw 2>/dev/null | grep 'openclaw@' | sed 's/.*openclaw@//' | tr -d '[:space:]' || true)
latest_ver=$(_npm view openclaw version 2>/dev/null || echo "")

if [[ -z "$current_ver" ]]; then
  current_ver="unknown"
fi

if [[ -z "$latest_ver" ]]; then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo '{"status":"error","error":"cannot_check_version","current":"'"$current_ver"'"}'
  else
    log_fail "Could not check latest version (npm registry unreachable?)"
    log_info "Current: $current_ver"
  fi
  exit 1
fi

update_available=false
if [[ "$current_ver" != "$latest_ver" ]]; then
  update_available=true
fi

log_info "Current: $current_ver"
log_info "Latest:  $latest_ver"

if $update_available; then
  log_ok "Update available: $current_ver → $latest_ver"
else
  log_ok "Already on latest version"
fi

# --- Check-only mode ---
if $CHECK_ONLY; then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    cat <<EOJSON
{
  "status": "ok",
  "current": "$current_ver",
  "latest": "$latest_ver",
  "update_available": $update_available
}
EOJSON
  fi
  exit 0
fi

# --- Bail if no update and not forced ---
if ! $update_available && ! $FORCE; then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo '{"status":"ok","message":"already_latest","current":"'"$current_ver"'","latest":"'"$latest_ver"'"}'
  else
    echo ""
    log_info "Nothing to do. Use --force to re-run the update anyway."
  fi
  exit 0
fi

# --- Step 2: Pre-update backup ---

backup_file=""
if ! $SKIP_BACKUP; then
  log_step "Creating pre-update backup..."
  backup_output=$(bash "$AAT_DIR/aat" backup --json 2>&1) || true

  if echo "$backup_output" | grep -q '"status":"ok"'; then
    backup_file=$(echo "$backup_output" | grep -o '"path":"[^"]*"' | head -1 | sed 's/"path":"//;s/"//')
    backup_size=$(echo "$backup_output" | grep -o '"compressed_bytes":[0-9]*' | head -1 | sed 's/"compressed_bytes"://')
    log_ok "Backup created: $(basename "$backup_file") ($(human_bytes "${backup_size:-0}"))"
  else
    log_warn "Backup may have failed — proceeding anyway"
    log_info "Output: $backup_output"
  fi
else
  log_info "Skipping backup (--skip-backup)"
fi

# --- Step 3: Stop gateway ---

log_step "Stopping gateway..."

gateway_was_running=false
if gateway_rpc_ok; then
  gateway_was_running=true
fi

if $gateway_was_running; then
  # Use openclaw CLI to stop cleanly
  openclaw_bin=$(find_openclaw)
  if [[ -n "$openclaw_bin" ]]; then
    node_bin=$(find_node)
    if [[ -n "$node_bin" ]]; then
      "$node_bin" "$openclaw_bin" gateway stop 2>/dev/null || true
    fi
  fi

  # Wait briefly for clean shutdown
  sleep 3

  # Verify it stopped
  if gateway_rpc_ok; then
    log_warn "Gateway still responding after stop — killing process"
    pkill -f "openclaw-gateway\|openclaw gateway" 2>/dev/null || true
    sleep 2
  fi

  log_ok "Gateway stopped"
else
  log_info "Gateway was not running"
fi

# --- Step 4: Run the update ---

log_step "Running openclaw-android updater..."

update_start=$(date +%s)
update_log=$(mktemp "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/aat-update-log.XXXXXX")

# The update.sh script may prompt for input (clawdhub install).
# Pipe 'n' to skip any interactive prompts.
update_ok=false
if echo "n" | bash "$OA_PLATFORM_UPDATE" > "$update_log" 2>&1; then
  update_ok=true
  log_ok "Update completed"
else
  log_fail "Update script returned an error"
fi

update_end=$(date +%s)
update_duration=$(( update_end - update_start ))

# Show key lines from update log
if [[ "$OUTPUT_FORMAT" == "human" ]]; then
  # Show version-related lines
  grep -iE "(openclaw|updated|installed|PASS|FAIL|WARN|SKIP|error)" "$update_log" 2>/dev/null | while read -r line; do
    echo "  │ $line"
  done | head -20
fi

# Get new version
new_ver=$(_npm list -g openclaw 2>/dev/null | grep 'openclaw@' | sed 's/.*openclaw@//' | tr -d '[:space:]' || true)
[[ -z "$new_ver" ]] && new_ver="unknown"

log_info "Version after update: $new_ver"

# --- Step 5: Verify installation ---

log_step "Verifying installation..."

verify_ok=false
if [[ -f "$OA_PLATFORM_VERIFY" ]]; then
  if bash "$OA_PLATFORM_VERIFY" > /dev/null 2>&1; then
    verify_ok=true
    log_ok "Platform verification passed"
  else
    log_warn "Platform verification had warnings"
  fi
else
  log_info "No verify script found, skipping"
  verify_ok=true  # Don't block on missing verify
fi

# --- Step 6: Restart gateway ---

log_step "Starting gateway..."

openclaw_bin=$(find_openclaw)
node_bin=$(find_node)

gateway_started=false
if [[ -n "$openclaw_bin" ]] && [[ -n "$node_bin" ]]; then
  "$node_bin" "$openclaw_bin" gateway start 2>/dev/null &
  disown 2>/dev/null || true

  log_info "Waiting for gateway RPC (up to ${MAX_STARTUP_WAIT}s)..."

  if wait_for_gateway "$MAX_STARTUP_WAIT"; then
    gateway_started=true
    log_ok "Gateway is running and responding"
  else
    log_fail "Gateway did not respond within ${MAX_STARTUP_WAIT}s"
  fi
else
  log_fail "Cannot find openclaw or node binary"
fi

# --- Step 7: Results ---

# Determine overall status
overall="ok"
if ! $update_ok; then
  overall="update_failed"
elif ! $gateway_started; then
  overall="gateway_failed"
fi

# Clean up
rm -f "$update_log"

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  cat <<EOJSON
{
  "status": "$overall",
  "previous_version": "$current_ver",
  "new_version": "$new_ver",
  "update_available": $update_available,
  "update_ok": $update_ok,
  "verify_ok": $verify_ok,
  "gateway_started": $gateway_started,
  "backup": $(if [[ -n "$backup_file" ]]; then echo "\"$backup_file\""; else echo "null"; fi),
  "duration_seconds": $update_duration,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOJSON
else
  echo ""
  echo -e "${BOLD}─── Update Summary ───${RESET}"
  echo ""

  case "$overall" in
    ok)
      if $update_available; then
        echo -e "  ${PASS} ${GREEN}Updated successfully: $current_ver → $new_ver${RESET}"
      else
        echo -e "  ${PASS} ${GREEN}Update re-applied (already on $new_ver)${RESET}"
      fi
      echo -e "  ${PASS} Gateway running"
      ;;
    update_failed)
      echo -e "  ${FAIL} ${RED}Update failed${RESET}"
      echo ""
      echo -e "  ${BOLD}Rollback:${RESET}"
      if [[ -n "$backup_file" ]]; then
        echo -e "    1. Restore backup: tar xzf $backup_file -C /"
        echo -e "    2. Restart gateway: openclaw gateway restart"
      else
        echo -e "    Try restarting: openclaw gateway restart"
      fi
      ;;
    gateway_failed)
      echo -e "  ${WARN} Update installed ($new_ver) but gateway didn't start"
      echo ""
      echo -e "  ${BOLD}Try:${RESET}"
      echo -e "    1. Check logs: aat logs --grep error --since 5m"
      echo -e "    2. Manual start: openclaw gateway start"
      if [[ -n "$backup_file" ]]; then
        echo -e "    3. Rollback: tar xzf $backup_file -C /"
      fi
      ;;
  esac

  echo ""
  echo -e "  ${DIM}Duration: ${update_duration}s${RESET}"
  [[ -n "$backup_file" ]] && echo -e "  ${DIM}Backup: $(basename "$backup_file")${RESET}"
fi

# Exit code
case "$overall" in
  ok) exit 0 ;;
  *) exit 1 ;;
esac
