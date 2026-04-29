#!/bin/bash
# Post-clone setup: check tool dependencies, render plist templates, install launchd schedule.
#
# Idempotent — safe to re-run after upgrades.
#
# Renders templates into $HOME/Library/LaunchAgents/ with the current user's
# $HOME / username / script path baked in. Templates themselves stay generic
# in the repo. Logs are written to $HOME/Library/Logs/claude-backup/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/claude-backup"
USERNAME="$(id -un)"
UID_NUM="$(id -u)"

echo "=== claude-backup setup ==="
echo "  Repo:        $SCRIPT_DIR"
echo "  User:        $USERNAME (uid $UID_NUM)"
echo "  Logs:        $LOG_DIR"
echo "  LaunchAgents: $LAUNCH_AGENTS"
echo

# -- 1. Tool dependency check --
echo "[1/3] Checking tool dependencies..."
missing=0

check_cmd() {
  if command -v "$1" &>/dev/null; then
    echo "  ok  $1"
  else
    echo "  -- $1 (install: $2)"
    missing=1
  fi
}

check_cmd rclone "brew install rclone"
check_cmd gh     "brew install gh"
check_cmd git    "xcode-select --install"

if [ "$missing" -eq 1 ]; then
  echo
  echo "  Some tools are missing. Install them above and re-run, or continue;"
  echo "  the launchd jobs will SKIP gracefully when their dependency is absent."
fi
echo

# -- 2. Prepare directories --
echo "[2/3] Preparing directories..."
mkdir -p "$LAUNCH_AGENTS" "$LOG_DIR"
echo "  ok  $LAUNCH_AGENTS"
echo "  ok  $LOG_DIR"
echo

# -- 3. Render templates and (re)load launchd jobs --
echo "[3/3] Installing launchd schedules..."

render_plist() {
  local name="$1"
  local cadence="$2"
  local src="$SCRIPT_DIR/templates/${name}.plist.template"
  local label="com.${USERNAME}.${name}"
  local dst="$LAUNCH_AGENTS/${label}.plist"

  if [ ! -f "$src" ]; then
    echo "  ERR template missing: $src" >&2
    return 1
  fi

  # Render with sed; use | as delimiter since paths contain /
  sed \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__USERNAME__|$USERNAME|g" \
    -e "s|__SCRIPT_DIR__|$SCRIPT_DIR|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$src" > "$dst"

  # Idempotent reload: bootout if present, then bootstrap.
  launchctl bootout "gui/${UID_NUM}/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/${UID_NUM}" "$dst"

  echo "  ok  $label  ($cadence)"
}

render_plist "claude-backup"      "rclone -> Google Drive, every 2h"
render_plist "claude-git-snapshot" "git snapshot -> backup/auto, every 6h"

echo
echo "Loaded jobs:"
launchctl list | grep "com\.${USERNAME}\.claude-" | sed 's/^/  /' || echo "  (none — bootstrap may have failed)"

echo
echo "Done. To verify health:  $SCRIPT_DIR/claude-backup.sh status"
