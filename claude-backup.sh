#!/bin/bash
# Unified backup dispatcher for ~/.claude.
#
# Subcommands:
#   drive            rclone sync ~/.claude to Google Drive
#   git              diff-aware auto-snapshot to backup/auto branch
#   git "<msg>" [f]  semantic commit + push to main (optional file list)
#   status           three-layer health report

set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Drift flag stays alongside the script (consumed by statusline via
# the ~/.claude/system/backup symlink). Logs live in the standard macOS
# log location so the repo directory stays clean for public distribution.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${CLAUDE_BACKUP_LOG_DIR:-$HOME/Library/Logs/claude-backup}"
mkdir -p "$LOG_DIR"
LOG_DRIVE="$LOG_DIR/rclone.log"
LOG_GIT="$LOG_DIR/git-snapshot.log"
LOG_DRIVE_LAUNCHD="$LOG_DIR/launchd-rclone.log"
LOG_GIT_LAUNCHD="$LOG_DIR/launchd-git-snapshot.log"
FLAG="$SCRIPT_DIR/.drift-status"
USER_NAME="$(id -un)"

# Git operations always run against the ~/.claude tree.
cd "$HOME/.claude"

# --- drive: rclone sync to Google Drive ------------------------------------
cmd_drive() {
  if ! curl -s --max-time 5 https://www.googleapis.com > /dev/null 2>&1; then
    echo "$(date '+%F %T') SKIP: no network" >> "$LOG_DRIVE"
    return 0
  fi
  local DATE
  DATE=$(date +%F)
  rclone sync "$HOME/.claude" "gdrive:backup/claude/latest" \
    --backup-dir "gdrive:backup/claude/${DATE}" \
    --exclude ".git/**" \
    --log-file "$LOG_DRIVE" \
    --log-level INFO
}

# --- git (no msg): diff-aware auto-snapshot to backup/auto -----------------
cmd_git_snapshot() {
  if ! curl -s --max-time 5 https://api.github.com > /dev/null 2>&1; then
    printf '%s SKIP: no network\n' "$(date '+%F %T')" >> "$LOG_GIT"
    return 0
  fi

  # Temp index — real .git/index is never modified.
  local TMP_INDEX
  TMP_INDEX=$(mktemp /tmp/.claude-snapshot-index.XXXXXX)
  trap 'rm -f "$TMP_INDEX"' RETURN
  cp .git/index "$TMP_INDEX" 2>/dev/null || true
  export GIT_INDEX_FILE="$TMP_INDEX"

  git add -A
  local NEW_TREE LAST_TREE PARENT COMMIT
  NEW_TREE=$(git write-tree)
  LAST_TREE=$(git rev-parse --verify -q "refs/heads/backup/auto^{tree}" 2>/dev/null || echo "")

  if [ "$NEW_TREE" = "$LAST_TREE" ]; then
    printf '%s SKIP: no change\n' "$(date '+%F %T')" >> "$LOG_GIT"
  else
    PARENT=$(git rev-parse --verify -q refs/heads/backup/auto 2>/dev/null || git rev-parse main)
    COMMIT=$(printf 'auto: %s\n' "$(date '+%F %T %Z')" | git commit-tree "$NEW_TREE" -p "$PARENT")
    git update-ref refs/heads/backup/auto "$COMMIT"
    git push origin "refs/heads/backup/auto:refs/heads/backup/auto" >> "$LOG_GIT" 2>&1
    printf '%s OK: %s\n' "$(date '+%F %T')" "$COMMIT" >> "$LOG_GIT"
  fi

  unset GIT_INDEX_FILE

  # Drift flag for statusline
  local COUNT LAST_PUSH_TS NOW DAYS_BEHIND
  COUNT=$(git status --porcelain | wc -l | tr -d ' ')
  LAST_PUSH_TS=$(git log -1 --format=%ct origin/main 2>/dev/null || echo 0)
  NOW=$(date +%s)
  DAYS_BEHIND=$(( (NOW - LAST_PUSH_TS) / 86400 ))

  if [ "$COUNT" -gt 5 ] || [ "$DAYS_BEHIND" -gt 3 ]; then
    printf '%s files / %sd behind' "$COUNT" "$DAYS_BEHIND" > "$FLAG"
  else
    rm -f "$FLAG"
  fi
}

# --- git "<msg>" [files...]: semantic commit + push main -------------------
cmd_git_commit() {
  local msg="$1"
  shift
  if [ -z "$msg" ]; then
    echo "Error: commit message required" >&2
    return 1
  fi
  local current_branch
  current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "(detached)")
  if [ "$current_branch" != "main" ]; then
    echo "Error: not on main branch (current: $current_branch); semantic commit aborted" >&2
    return 1
  fi
  if [ $# -gt 0 ]; then
    git add -- "$@"
  else
    git add -A
  fi
  if git diff --cached --quiet; then
    echo "No staged changes — nothing to commit"
    return 0
  fi
  git commit -m "$msg"
  git push origin main
  rm -f "$FLAG"
}

# --- status: three-layer health report -------------------------------------
cmd_status() {
  set +e
  echo "=== ~/.claude backup status ==="
  echo

  local main_oneline main_time auto_oneline auto_time
  main_oneline=$(git log main --oneline -1 2>/dev/null || echo '(none)')
  main_time=$(git log main --format='%ci' -1 2>/dev/null || echo '(none)')
  echo "[git main]"
  echo "  commit:  $main_oneline"
  echo "           $main_time"
  echo "  pending: $(git status --short | wc -l | tr -d ' ') file(s)"
  echo

  auto_oneline=$(git log backup/auto --oneline -1 2>/dev/null || echo '(none)')
  auto_time=$(git log backup/auto --format='%ci' -1 2>/dev/null || echo '(none)')
  echo "[git backup/auto]"
  echo "  commit:  $auto_oneline"
  echo "           $auto_time"
  if [ -s "$LOG_GIT" ]; then
    echo "  recent log:"
    grep -E 'OK:|SKIP:' "$LOG_GIT" | tail -3 | sed 's/^/    /'
  fi
  echo

  echo "[drift flag]"
  if [ -f "$FLAG" ]; then
    echo "  $(cat "$FLAG")"
  else
    echo "  synced"
  fi
  echo

  echo "[rclone]"
  if [ -s "$LOG_DRIVE" ]; then
    local last_activity skips stats
    last_activity=$(grep -oE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_DRIVE" | tail -1)
    echo "  last activity: ${last_activity:-(none)}"
    skips=$(grep "SKIP" "$LOG_DRIVE" | tail -3)
    if [ -n "$skips" ]; then
      echo "  recent SKIP:"
      printf '%s\n' "$skips" | sed 's/^/    /'
    fi
    stats=$(grep -E "Transferred|Errors|Elapsed" "$LOG_DRIVE" | tail -4)
    if [ -n "$stats" ]; then
      echo "  stats:"
      printf '%s\n' "$stats" | sed 's/^/    /'
    fi
  else
    echo "  (no log)"
  fi
  echo

  echo "[launchd jobs]"
  launchctl list | grep "com\.${USER_NAME}\.claude-" | while IFS=$'\t' read -r pid exit_code label; do
    local state
    if [ "$pid" = "-" ]; then
      state="not running"
    else
      state="pid $pid"
    fi
    printf '  %-34s last exit %-3s %s\n' "$label" "$exit_code" "$state"
  done
  echo

  local f
  for f in "$LOG_DRIVE_LAUNCHD" "$LOG_GIT_LAUNCHD"; do
    if [ -s "$f" ]; then
      echo "[launchd errors: $(basename "$f")]"
      sed 's/^/  /' "$f"
      echo
    fi
  done
  set -e
}

# --- dispatch --------------------------------------------------------------
CMD="${1:-}"
shift || true

case "$CMD" in
  drive)
    cmd_drive
    ;;
  git)
    if [ $# -eq 0 ]; then
      cmd_git_snapshot
    else
      cmd_git_commit "$@"
    fi
    ;;
  status)
    cmd_status
    ;;
  *)
    echo "Usage: claude-backup.sh {drive|git [\"msg\" file...]|status}" >&2
    exit 1
    ;;
esac
