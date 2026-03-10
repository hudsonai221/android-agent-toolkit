#!/data/data/com.termux/files/usr/bin/bash
# aat restore — restore from an aat backup archive
#
# Restores files from a backup created by `aat backup`:
#   openclaw-config/ → ~/.openclaw/
#   workspace/       → ~/clawd/
#   crontab.txt      → crontab (optional)
#
# Usage: aat restore <archive> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# --- Defaults ---
BACKUP_DIR="$HOME/backups"
ARCHIVE=""
DRY_RUN=false
OUTPUT_FORMAT="human"  # human | json
SCOPE="all"            # all | config | workspace | crontab
LIST_CONTENTS=false
FORCE=false
SKIP_CRONTAB=false
STOP_GATEWAY=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true; shift ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    --config-only) SCOPE="config"; shift ;;
    --workspace-only) SCOPE="workspace"; shift ;;
    --crontab-only) SCOPE="crontab"; shift ;;
    --skip-crontab) SKIP_CRONTAB=true; shift ;;
    --list|-l) LIST_CONTENTS=true; shift ;;
    --force|-f) FORCE=true; shift ;;
    --latest) ARCHIVE="__latest__"; shift ;;
    -h|--help)
      cat <<EOF
Usage: aat restore <archive|--latest> [options]

Restore from an aat backup archive.

Arguments:
  <archive>       Path to the backup .tar.gz file
  --latest        Automatically use the most recent backup

Options:
  --list, -l        List archive contents without restoring
  --dry-run, -n     Show what would be restored without making changes
  --config-only     Only restore OpenClaw config (~/.openclaw/)
  --workspace-only  Only restore workspace (~/clawd/)
  --crontab-only    Only restore crontab
  --skip-crontab    Restore everything except crontab
  --force, -f       Overwrite without confirmation
  --json            Output as JSON
  -h, --help        Show this help

Examples:
  aat restore ~/backups/aat-backup-20260310-120000.tar.gz
  aat restore --latest                    # Use most recent backup
  aat restore --latest --list             # Inspect latest backup
  aat restore --latest --dry-run          # Preview restore
  aat restore backup.tar.gz --config-only # Only restore config
  aat restore backup.tar.gz --force       # No confirmation prompt

Archive structure (created by aat backup):
  openclaw-config/    → ~/.openclaw/
  workspace/          → ~/clawd/
  crontab.txt         → system crontab
EOF
      exit 0
      ;;
    -*)
      echo "Error: unknown option '$1'" >&2
      echo "Run 'aat restore --help' for usage." >&2
      exit 1
      ;;
    *)
      if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE="$1"
      else
        echo "Error: unexpected argument '$1'" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# --- Resolve archive ---

find_latest_backup() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo ""
    return
  fi
  find "$BACKUP_DIR" -maxdepth 1 -name 'aat-backup-*.tar.gz' 2>/dev/null \
    | sort -r \
    | head -n1
}

if [[ "$ARCHIVE" == "__latest__" ]]; then
  ARCHIVE=$(find_latest_backup)
  if [[ -z "$ARCHIVE" ]]; then
    echo "Error: no backups found in ${BACKUP_DIR}" >&2
    exit 1
  fi
  if [[ "$OUTPUT_FORMAT" == "human" ]] && ! $LIST_CONTENTS; then
    echo -e "${INFO} Using latest backup: $(basename "$ARCHIVE")"
  fi
elif [[ -z "$ARCHIVE" ]]; then
  echo "Error: no archive specified" >&2
  echo "Usage: aat restore <archive|--latest> [options]" >&2
  echo "Run 'aat restore --help' for usage." >&2
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Error: archive not found: ${ARCHIVE}" >&2
  exit 1
fi

# --- Validate archive ---
if ! tar tzf "$ARCHIVE" &>/dev/null; then
  echo "Error: invalid or corrupt archive: ${ARCHIVE}" >&2
  exit 1
fi

# --- List mode ---
if $LIST_CONTENTS; then
  # Get archive info
  archive_size=$(stat -c%s "$ARCHIVE" 2>/dev/null || echo 0)
  archive_name=$(basename "$ARCHIVE")
  archive_mtime=$(stat -c%y "$ARCHIVE" 2>/dev/null | cut -d. -f1)

  # Detect mode from filename
  mode="essential"
  [[ "$archive_name" == *"-full-"* ]] && mode="full"

  # Count files by category
  config_count=$(tar tzf "$ARCHIVE" 2>/dev/null | grep -c '^./openclaw-config/' || true)
  workspace_count=$(tar tzf "$ARCHIVE" 2>/dev/null | grep -c '^./workspace/' || true)
  has_crontab=$(tar tzf "$ARCHIVE" 2>/dev/null | grep -c '^./crontab.txt$' || true)
  total_files=$(tar tzf "$ARCHIVE" 2>/dev/null | grep -v '/$' | wc -l)

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    files_json="["
    first=true
    while IFS= read -r f; do
      [[ "$f" == */ ]] && continue  # skip directories
      $first || files_json+=","
      first=false
      files_json+="\"$f\""
    done < <(tar tzf "$ARCHIVE" 2>/dev/null)
    files_json+="]"

    cat <<EOJSON
{
  "archive": "${ARCHIVE}",
  "size_bytes": ${archive_size},
  "size_human": "$(human_bytes $archive_size)",
  "mode": "${mode}",
  "created": "${archive_mtime}",
  "total_files": ${total_files},
  "config_files": ${config_count},
  "workspace_files": ${workspace_count},
  "has_crontab": $([ "$has_crontab" -gt 0 ] && echo true || echo false),
  "files": ${files_json}
}
EOJSON
  else
    echo -e "${BOLD}Archive Contents${RESET}"
    echo ""
    echo -e "  ${BOLD}File:${RESET}      ${archive_name}"
    echo -e "  ${BOLD}Size:${RESET}      $(human_bytes $archive_size)"
    echo -e "  ${BOLD}Created:${RESET}   ${archive_mtime}"
    echo -e "  ${BOLD}Mode:${RESET}      ${mode}"
    echo -e "  ${BOLD}Files:${RESET}     ${total_files} total"
    echo ""

    if (( config_count > 0 )); then
      echo -e "  ${INFO} ${BOLD}OpenClaw Config${RESET} (${config_count} files) → ~/.openclaw/"
      tar tzf "$ARCHIVE" 2>/dev/null | grep '^./openclaw-config/' | grep -v '/$' | while read -r f; do
        rel="${f#./openclaw-config/}"
        echo -e "     ${DIM}${rel}${RESET}"
      done
      echo ""
    fi

    if (( workspace_count > 0 )); then
      echo -e "  ${INFO} ${BOLD}Workspace${RESET} (${workspace_count} files) → ~/clawd/"
      tar tzf "$ARCHIVE" 2>/dev/null | grep '^./workspace/' | grep -v '/$' | while read -r f; do
        rel="${f#./workspace/}"
        echo -e "     ${DIM}${rel}${RESET}"
      done
      echo ""
    fi

    if (( has_crontab > 0 )); then
      echo -e "  ${INFO} ${BOLD}Crontab${RESET} (1 file)"
      echo ""
    fi
  fi
  exit 0
fi

# --- Build restore plan ---

TMPDIR="${TMPDIR:-$PREFIX/tmp}"
mkdir -p "$TMPDIR"
restore_plan=$(mktemp "${TMPDIR}/aat-restore-plan.XXXXXX")
trap 'rm -f "$restore_plan"' EXIT

# Map archive paths to destination paths
while IFS= read -r archive_path; do
  [[ "$archive_path" == */ ]] && continue  # skip directories
  clean="${archive_path#./}"

  dest=""
  category=""

  if [[ "$clean" == "openclaw-config/"* ]]; then
    category="config"
    rel="${clean#openclaw-config/}"
    dest="$HOME/.openclaw/${rel}"
  elif [[ "$clean" == "workspace/"* ]]; then
    category="workspace"
    rel="${clean#workspace/}"
    dest="$HOME/clawd/${rel}"
  elif [[ "$clean" == "crontab.txt" ]]; then
    category="crontab"
    dest="__crontab__"
  else
    category="other"
    dest=""
  fi

  # Apply scope filter
  case "$SCOPE" in
    config)    [[ "$category" != "config" ]] && continue ;;
    workspace) [[ "$category" != "workspace" ]] && continue ;;
    crontab)   [[ "$category" != "crontab" ]] && continue ;;
    all)
      if $SKIP_CRONTAB && [[ "$category" == "crontab" ]]; then
        continue
      fi
      ;;
  esac

  if [[ -n "$dest" ]]; then
    # Check if destination exists (for conflict reporting)
    exists="no"
    [[ "$dest" != "__crontab__" ]] && [[ -f "$dest" ]] && exists="yes"
    [[ "$dest" == "__crontab__" ]] && crontab -l &>/dev/null && exists="yes"

    echo "${archive_path}|${dest}|${category}|${exists}" >> "$restore_plan"
  fi
done < <(tar tzf "$ARCHIVE" 2>/dev/null)

total_restore=$(wc -l < "$restore_plan")
conflicts=$(grep '|yes$' "$restore_plan" | wc -l)
new_files=$((total_restore - conflicts))

if (( total_restore == 0 )); then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo '{"status":"empty","message":"No files match the restore scope"}'
  else
    echo -e "${WARN} No files match the restore scope (${SCOPE})"
  fi
  exit 0
fi

# --- Dry run ---
if $DRY_RUN; then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo '{"status":"dry_run","scope":"'"$SCOPE"'","total_files":'"$total_restore"',"new_files":'"$new_files"',"conflicts":'"$conflicts"',"files":['
    first=true
    while IFS='|' read -r src dest cat exists; do
      $first || echo ","
      first=false
      display_dest="$dest"
      [[ "$dest" == "__crontab__" ]] && display_dest="(crontab)"
      printf '{"source":"%s","destination":"%s","category":"%s","exists":%s}' \
        "$src" "$display_dest" "$cat" "$( [[ "$exists" == "yes" ]] && echo true || echo false )"
    done < "$restore_plan"
    echo ']}'
  else
    echo -e "${BOLD}Restore Preview${RESET} (${SCOPE} scope)"
    echo ""
    echo -e "  ${INFO} ${total_restore} files to restore (${new_files} new, ${conflicts} existing)"
    echo ""

    current_cat=""
    while IFS='|' read -r src dest cat exists; do
      if [[ "$cat" != "$current_cat" ]]; then
        current_cat="$cat"
        case "$cat" in
          config)    echo -e "  ${BOLD}OpenClaw Config → ~/.openclaw/${RESET}" ;;
          workspace) echo -e "  ${BOLD}Workspace → ~/clawd/${RESET}" ;;
          crontab)   echo -e "  ${BOLD}Crontab${RESET}" ;;
        esac
      fi

      if [[ "$dest" == "__crontab__" ]]; then
        label="crontab"
      else
        label="${dest/#$HOME/\~}"
      fi

      if [[ "$exists" == "yes" ]]; then
        echo -e "    ${WARN} ${label} ${DIM}(overwrite)${RESET}"
      else
        echo -e "    ${PASS} ${label} ${DIM}(new)${RESET}"
      fi
    done < "$restore_plan"

    echo ""
    echo -e "  ${INFO} Run without --dry-run to restore"
  fi
  exit 0
fi

# --- Confirmation ---
if ! $FORCE && [[ "$OUTPUT_FORMAT" == "human" ]]; then
  echo -e "${BOLD}Restore from:${RESET} $(basename "$ARCHIVE")"
  echo -e "${BOLD}Scope:${RESET}        ${SCOPE}"
  echo -e "${BOLD}Files:${RESET}        ${total_restore} (${new_files} new, ${conflicts} to overwrite)"
  echo ""

  if (( conflicts > 0 )); then
    echo -e "${WARN} ${conflicts} existing file(s) will be overwritten"
  fi

  # In non-interactive mode (cron/pipe), skip confirmation with force
  if [[ ! -t 0 ]]; then
    echo -e "${FAIL} Non-interactive mode: use --force to skip confirmation" >&2
    exit 1
  fi

  echo ""
  read -r -p "Proceed? [y/N] " confirm
  case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *)
      echo "Restore cancelled."
      exit 0
      ;;
  esac
  echo ""
fi

# --- Execute restore ---

start_time=$(date +%s)
restored=0
errors=0
error_files=()

# Extract to staging area first (safer than direct overwrite)
staging="${TMPDIR}/aat-restore-staging-$$"
rm -rf "$staging"
mkdir -p "$staging"

if ! tar xzf "$ARCHIVE" -C "$staging" 2>/dev/null; then
  echo "Error: failed to extract archive" >&2
  rm -rf "$staging"
  exit 1
fi

while IFS='|' read -r src dest cat exists; do
  # Source file in staging
  staged_file="${staging}/${src#./}"

  if [[ ! -f "$staged_file" ]]; then
    errors=$((errors + 1))
    error_files+=("$src: not found in archive")
    continue
  fi

  if [[ "$dest" == "__crontab__" ]]; then
    # Restore crontab
    if crontab "${staging}/crontab.txt" 2>/dev/null; then
      restored=$((restored + 1))
    else
      errors=$((errors + 1))
      error_files+=("crontab: failed to install")
    fi
  else
    # Restore regular file
    dest_dir=$(dirname "$dest")
    if mkdir -p "$dest_dir" 2>/dev/null && cp "$staged_file" "$dest" 2>/dev/null; then
      restored=$((restored + 1))
    else
      errors=$((errors + 1))
      error_files+=("$dest: copy failed")
    fi
  fi
done < "$restore_plan"

# Clean up staging
rm -rf "$staging"

end_time=$(date +%s)
duration=$((end_time - start_time))

# --- Output ---
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  error_json="[]"
  if (( errors > 0 )); then
    error_json="["
    first=true
    for e in "${error_files[@]}"; do
      $first || error_json+=","
      first=false
      error_json+="\"$e\""
    done
    error_json+="]"
  fi

  cat <<EOJSON
{
  "status": "$([ $errors -eq 0 ] && echo ok || echo partial)",
  "archive": "${ARCHIVE}",
  "scope": "${SCOPE}",
  "restored": ${restored},
  "errors": ${errors},
  "error_details": ${error_json},
  "duration_seconds": ${duration},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOJSON
else
  if (( errors == 0 )); then
    echo -e "  ${PASS} Restore completed successfully"
  else
    echo -e "  ${WARN} Restore completed with ${errors} error(s)"
    for e in "${error_files[@]}"; do
      echo -e "     ${FAIL} ${e}"
    done
  fi
  echo ""
  echo -e "  ${BOLD}Archive:${RESET}   $(basename "$ARCHIVE")"
  echo -e "  ${BOLD}Scope:${RESET}     ${SCOPE}"
  echo -e "  ${BOLD}Restored:${RESET}  ${restored} file(s)"
  echo -e "  ${BOLD}Duration:${RESET}  ${duration}s"

  if (( errors == 0 )); then
    echo ""
    echo -e "  ${DIM}Tip: restart the gateway if you restored config files${RESET}"
    echo -e "  ${DIM}     openclaw gateway restart${RESET}"
  fi
fi
