#!/usr/bin/env bash
# Android Agent Toolkit — Installer
# Usage: curl -sL https://raw.githubusercontent.com/hudsonai221/android-agent-toolkit/main/install.sh | bash
#
# Or clone + run locally:
#   git clone https://github.com/hudsonai221/android-agent-toolkit.git
#   cd android-agent-toolkit && bash install.sh

set -euo pipefail

# Colors
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m'
  BOLD='\033[1m' RESET='\033[0m'
else
  GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

info()  { echo -e "${GREEN}▸${RESET} $*"; }
warn()  { echo -e "${YELLOW}▸${RESET} $*"; }
error() { echo -e "${RED}▸${RESET} $*" >&2; }
die()   { error "$@"; exit 1; }

AAT_REPO="https://github.com/hudsonai221/android-agent-toolkit.git"
AAT_DIR="${AAT_INSTALL_DIR:-$HOME/android-agent-toolkit}"

# ── Pre-flight checks ──────────────────────────────────────────────

echo -e "${BOLD}Android Agent Toolkit — Installer${RESET}"
echo ""

# Check we're on a reasonable system
if ! command -v bash &>/dev/null; then
  die "bash is required"
fi

if ! command -v git &>/dev/null; then
  die "git is required. Install with: pkg install git (Termux) or apt install git"
fi

# Detect Termux
IS_TERMUX=false
if [[ -d "/data/data/com.termux" ]]; then
  IS_TERMUX=true
  info "Detected Termux environment"
fi

# ── Install / Update ───────────────────────────────────────────────

if [[ -d "$AAT_DIR/.git" ]]; then
  info "Existing installation found at $AAT_DIR — updating..."
  cd "$AAT_DIR"
  git pull --ff-only origin main 2>/dev/null || {
    warn "Fast-forward pull failed. Trying fetch + reset..."
    git fetch origin main
    git reset --hard origin/main
  }
else
  info "Cloning to $AAT_DIR..."
  git clone "$AAT_REPO" "$AAT_DIR"
  cd "$AAT_DIR"
fi

# Make entrypoint executable
chmod +x "$AAT_DIR/aat"

# ── PATH setup ─────────────────────────────────────────────────────

# Check if aat is already in PATH
if command -v aat &>/dev/null; then
  info "aat is already in PATH"
else
  # Determine shell config
  SHELL_RC=""
  if [[ -f "$HOME/.bashrc" ]]; then
    SHELL_RC="$HOME/.bashrc"
  elif [[ -f "$HOME/.zshrc" ]]; then
    SHELL_RC="$HOME/.zshrc"
  elif [[ -f "$HOME/.profile" ]]; then
    SHELL_RC="$HOME/.profile"
  fi

  PATH_LINE="export PATH=\"$AAT_DIR:\$PATH\""

  if [[ -n "$SHELL_RC" ]]; then
    # Check if already added
    if grep -qF "android-agent-toolkit" "$SHELL_RC" 2>/dev/null; then
      info "PATH entry already in $SHELL_RC"
    else
      echo "" >> "$SHELL_RC"
      echo "# Android Agent Toolkit" >> "$SHELL_RC"
      echo "$PATH_LINE" >> "$SHELL_RC"
      info "Added to PATH in $SHELL_RC"
    fi
  else
    warn "Could not detect shell config. Add this to your profile:"
    echo "  $PATH_LINE"
  fi

  # Add to current session
  export PATH="$AAT_DIR:$PATH"
fi

# ── Verify ─────────────────────────────────────────────────────────

echo ""
info "Verifying installation..."

if "$AAT_DIR/aat" version &>/dev/null; then
  VERSION=$("$AAT_DIR/aat" version)
  echo -e "${GREEN}✓${RESET} Installed: ${BOLD}${VERSION}${RESET}"
else
  die "Installation verification failed"
fi

# Quick health check if on Termux with OpenClaw
if $IS_TERMUX && command -v openclaw &>/dev/null; then
  echo ""
  info "Running quick health check..."
  "$AAT_DIR/aat" health --brief 2>/dev/null || warn "Health check had warnings (this is normal on first install)"
fi

echo ""
echo -e "${GREEN}${BOLD}Done!${RESET} Run ${BOLD}aat help${RESET} to get started."
if [[ -n "${SHELL_RC:-}" ]] && ! command -v aat &>/dev/null; then
  echo -e "  ${YELLOW}→ Restart your shell or run: source $SHELL_RC${RESET}"
fi
