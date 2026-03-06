#!/data/data/com.termux/files/usr/bin/bash
# aat backup — backup workspace, config, and credentials for OpenClaw on Android
#
# Creates a timestamped tar.gz containing:
#   Essential (default):
#     - ~/.openclaw/openclaw.json (main config)
#     - ~/.openclaw/openclaw.json.bak
#     - ~/.openclaw/credentials/ (API keys, tokens)
#     - ~/.openclaw/identity/ (device identity)
#     - ~/.openclaw/cron/ (cron job configs)
#     - ~/.openclaw/workspace/ (workspace registry)
#     - ~/clawd/ (workspace: memory, skills, config — excludes node_modules)
#     - crontab (if any)
#   Full (--full):
#     - Everything above plus all of ~/.openclaw/
#       (agents/sessions, completions, memory vectors, media, logs, telegram state)
#
# Usage: aat backup [--full] [--output PATH] [--list] [--dry-run] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- Defaults ---
BACKUP_DIR="$HOME/backups"
BACKUP_MODE="essential"  # essential | full
OUTPUT_PATH=""
DRY_RUN=false
LIST_MODE=false
OUTPUT_FORMAT="human"  # human | json

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) BACKUP_MODE="full"; shift ;;
    --output|-o) OUTPUT_PATH="$2"; shift 2 ;;
    --list|-l) LIST_MODE=true; shift ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    -h|--help)
      cat <<EOF
Usage: aat backup [options]

Create a backup of OpenClaw workspace and configuration.

Options:
  --full        Include session history, memory vectors, media, logs
  --output, -o  Output path (default: ~/backups/aat-backup-TIMESTAMP.tar.gz)
  --list, -l    List existing backups
  --dry-run, -n Show what would be backed up without creating archive
  --json        Output as JSON
  -h, --help    Show this help

Examples:
  aat backup                  # Essential backup to ~/backups/
  aat backup --full           # Full backup including session data
  aat backup -o /sdcard/      # Backup to external storage
  aat backup --list           # List existing backups
  aat backup --dry-run        # Preview what would be included

What's included:
  Essential (default):
    ~/.openclaw/openclaw.json       Main configuration
    ~/.openclaw/credentials/        API keys and tokens
    ~/.openclaw/identity/           Device identity
    ~/.openclaw/cron/               Cron job definitions
    ~/.openclaw/workspace/          Workspace registry
    ~/clawd/                        Workspace (memory, skills, config)
    crontab                         System cron schedule

  Full (--full): everything above plus:
    ~/.openclaw/agents/             Session history
    ~/.openclaw/completions/        Completion cache
    ~/.openclaw/memory/             Memory vectors
    ~/.openclaw/media/              Cached media
    ~/.openclaw/logs/               Gateway logs
    ~/.openclaw/telegram/           Telegram session state
    ~/.openclaw/devices/            Device registry
    ~/.openclaw/delivery-queue/     Pending deliveries
    ~/.openclaw/subagents/          Sub-agent configs
EOF
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      echo "Run 'aat backup --help' for usage." >&2
      exit 1
      ;;
  esac
done

# --- List mode ---
if $LIST_MODE; then
  if [[ ! -d "$BACKUP_DIR" ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo '{"backups":[],"total":0}'
    else
      echo "No backups found (${BACKUP_DIR} does not exist)"
    fi
    exit 0
  fi

  backups=()
  while IFS= read -r -d '' f; do
    backups+=("$f")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -name 'aat-backup-*.tar.gz' -print0 2>/dev/null | sort -z)

  if [[ ${#backups[@]} -eq 0 ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo '{"backups":[],"total":0}'
    else
      echo "No backups found in ${BACKUP_DIR}"
    fi
    exit 0
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo '{"backups":['
    first=true
    for b in "${backups[@]}"; do
      size=$(stat -c%s "$b" 2>/dev/null || echo 0)
      mtime=$(stat -c%Y "$b" 2>/dev/null || echo 0)
      $first || echo ","
      first=false
      printf '{"path":"%s","size":%d,"modified":%d}' "$b" "$size" "$mtime"
    done
    echo '],"total":'${#backups[@]}'}'
  else
    echo -e "${BOLD}Existing Backups${RESET} (${BACKUP_DIR})"
    echo ""
    for b in "${backups[@]}"; do
      size=$(du -h "$b" 2>/dev/null | awk '{print $1}')
      mtime=$(stat -c%y "$b" 2>/dev/null | cut -d. -f1)
      name=$(basename "$b")
      # Extract mode from filename
      mode="essential"
      [[ "$name" == *"-full-"* ]] && mode="full"
      echo -e "  ${INFO} ${name}"
      echo -e "     Size: ${size}  Created: ${mtime}  Mode: ${mode}"
    done
    echo ""
    echo "${#backups[@]} backup(s) found"
  fi
  exit 0
fi

# --- Build file list ---

# Temporary manifest file (use $TMPDIR for Termux compatibility)
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
mkdir -p "$TMPDIR"
manifest=$(mktemp "${TMPDIR}/aat-backup-manifest.XXXXXX")
trap 'rm -f "$manifest"' EXIT

# Helper: add a path to manifest if it exists
add_path() {
  local path="$1"
  if [[ -e "$path" ]]; then
    echo "$path" >> "$manifest"
  fi
}

# Essential: OpenClaw config files
add_path "$HOME/.openclaw/openclaw.json"
add_path "$HOME/.openclaw/openclaw.json.bak"
add_path "$HOME/.openclaw/update-check.json"

# Essential: OpenClaw directories
essential_dirs=(
  "$HOME/.openclaw/credentials"
  "$HOME/.openclaw/identity"
  "$HOME/.openclaw/cron"
  "$HOME/.openclaw/workspace"
)

for d in "${essential_dirs[@]}"; do
  if [[ -d "$d" ]]; then
    find "$d" -type f ! -path "*/.git/*" >> "$manifest" 2>/dev/null
  fi
done

# Essential: Workspace (~/clawd/) — exclude node_modules, .git, canvas builds
if [[ -d "$HOME/clawd" ]]; then
  find "$HOME/clawd" -type f \
    ! -path "*/.git/*" \
    ! -path "*/node_modules/*" \
    ! -path "*/canvas/dist/*" \
    ! -path "*/canvas/node_modules/*" \
    ! -name "*.tmp" \
    ! -name "*.log" \
    >> "$manifest" 2>/dev/null
fi

# Essential: Crontab
crontab_file=$(mktemp "${TMPDIR}/aat-crontab.XXXXXX")
crontab_saved=false
if crontab -l > "$crontab_file" 2>/dev/null && [[ -s "$crontab_file" ]]; then
  crontab_saved=true
  echo "$crontab_file" >> "$manifest"
fi

# Full mode: add remaining ~/.openclaw directories
if [[ "$BACKUP_MODE" == "full" ]]; then
  full_dirs=(
    "$HOME/.openclaw/agents"
    "$HOME/.openclaw/completions"
    "$HOME/.openclaw/memory"
    "$HOME/.openclaw/media"
    "$HOME/.openclaw/logs"
    "$HOME/.openclaw/telegram"
    "$HOME/.openclaw/devices"
    "$HOME/.openclaw/delivery-queue"
    "$HOME/.openclaw/subagents"
    "$HOME/.openclaw/canvas"
  )

  for d in "${full_dirs[@]}"; do
    if [[ -d "$d" ]]; then
      find "$d" -type f >> "$manifest" 2>/dev/null
    fi
  done
fi

# Count and size
file_count=$(wc -l < "$manifest")
total_size=0
while IFS= read -r f; do
  if [[ -f "$f" ]]; then
    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
    total_size=$((total_size + fsize))
  fi
done < "$manifest"

# --- Dry run ---
if $DRY_RUN; then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    cat <<EOJSON
{
  "mode": "${BACKUP_MODE}",
  "file_count": ${file_count},
  "total_bytes": ${total_size},
  "total_human": "$(human_bytes $total_size)",
  "files": [
EOJSON
    first=true
    while IFS= read -r f; do
      $first || echo ","
      first=false
      # Make paths relative for readability
      rel="${f/#$HOME/\~}"
      printf '    "%s"' "$rel"
    done < "$manifest"
    cat <<EOJSON

  ]
}
EOJSON
  else
    echo -e "${BOLD}Backup Preview${RESET} (${BACKUP_MODE} mode)"
    echo ""
    echo -e "${INFO} ${file_count} files, $(human_bytes $total_size) uncompressed"
    echo ""

    # Group files by top-level directory for readability
    echo -e "${BOLD}Files:${RESET}"
    prev_dir=""
    while IFS= read -r f; do
      rel="${f/#$HOME/\~}"
      # Extract top-level group
      dir=$(echo "$rel" | sed 's|/[^/]*$||')
      if [[ "$dir" != "$prev_dir" ]]; then
        echo ""
        echo -e "  ${DIM}${dir}/${RESET}"
        prev_dir="$dir"
      fi
      basename=$(basename "$f")
      fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
      echo -e "    ${basename}  ${DIM}($(human_bytes $fsize))${RESET}"
    done < "$manifest"
    echo ""
    echo -e "${INFO} Run without --dry-run to create the backup"
  fi

  rm -f "$crontab_file"
  exit 0
fi

# --- Create backup ---

# Determine output path
timestamp=$(date +%Y%m%d-%H%M%S)
mode_tag=""
[[ "$BACKUP_MODE" == "full" ]] && mode_tag="-full"

if [[ -n "$OUTPUT_PATH" ]]; then
  # If OUTPUT_PATH is a directory, put the archive in it
  if [[ -d "$OUTPUT_PATH" ]]; then
    backup_file="${OUTPUT_PATH%/}/aat-backup${mode_tag}-${timestamp}.tar.gz"
  else
    backup_file="$OUTPUT_PATH"
  fi
else
  mkdir -p "$BACKUP_DIR"
  backup_file="${BACKUP_DIR}/aat-backup${mode_tag}-${timestamp}.tar.gz"
fi

# Ensure parent directory exists
backup_parent=$(dirname "$backup_file")
if [[ ! -d "$backup_parent" ]]; then
  echo "Error: output directory does not exist: ${backup_parent}" >&2
  rm -f "$crontab_file"
  exit 1
fi

if [[ "$OUTPUT_FORMAT" == "human" ]]; then
  echo -e "${BOLD}Creating ${BACKUP_MODE} backup...${RESET}"
  echo -e "  ${INFO} ${file_count} files, $(human_bytes $total_size) uncompressed"
fi

start_time=$(date +%s)

# Create a staging directory with clean structure
# (toybox tar on Android doesn't support --transform)
staging="${TMPDIR}/aat-backup-staging"
rm -rf "$staging"
mkdir -p "$staging"

while IFS= read -r f; do
  if [[ "$f" == "${HOME}/.openclaw"* ]]; then
    # ~/.openclaw/... → openclaw-config/...
    rel="${f#${HOME}/.openclaw/}"
    dest="${staging}/openclaw-config/${rel}"
  elif [[ "$f" == "${HOME}/clawd"* ]]; then
    # ~/clawd/... → workspace/...
    rel="${f#${HOME}/clawd/}"
    dest="${staging}/workspace/${rel}"
  elif [[ "$f" == *"aat-crontab"* ]]; then
    dest="${staging}/crontab.txt"
  else
    # Fallback: use basename
    dest="${staging}/$(basename "$f")"
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done < "$manifest"

# Create the archive from staging
tar czf "$backup_file" -C "$staging" .

end_time=$(date +%s)
duration=$((end_time - start_time))

# Clean up
rm -rf "$staging" "$crontab_file"

# Get final archive size
archive_size=$(stat -c%s "$backup_file" 2>/dev/null || echo 0)

# --- Output ---
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  cat <<EOJSON
{
  "status": "ok",
  "mode": "${BACKUP_MODE}",
  "path": "${backup_file}",
  "file_count": ${file_count},
  "uncompressed_bytes": ${total_size},
  "compressed_bytes": ${archive_size},
  "duration_seconds": ${duration},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOJSON
else
  compression_pct=0
  if (( total_size > 0 )); then
    compression_pct=$(( 100 - (archive_size * 100 / total_size) ))
  fi

  echo ""
  echo -e "  ${PASS} Backup created successfully"
  echo ""
  echo -e "  ${BOLD}File:${RESET}        ${backup_file}"
  echo -e "  ${BOLD}Mode:${RESET}        ${BACKUP_MODE}"
  echo -e "  ${BOLD}Files:${RESET}       ${file_count}"
  echo -e "  ${BOLD}Size:${RESET}        $(human_bytes $archive_size) (${compression_pct}% compression)"
  echo -e "  ${BOLD}Duration:${RESET}    ${duration}s"
  echo ""
  echo -e "  ${DIM}Restore: tar xzf ${backup_file}${RESET}"
fi
