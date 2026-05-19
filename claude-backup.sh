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

# Machine-local config (never committed; lives outside this public repo).
# Single home for every non-committable setting — log directory, alert
# recipient, SMTP credentials. Sourced here, before LOG_DIR is derived, so a
# custom log location takes effect. Path overridable via CLAUDE_BACKUP_CONFIG.
CLAUDE_BACKUP_CONFIG="${CLAUDE_BACKUP_CONFIG:-$HOME/.config/claude-backup/config}"
if [ -f "$CLAUDE_BACKUP_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$CLAUDE_BACKUP_CONFIG" || echo "claude-backup: WARNING — failed to source $CLAUDE_BACKUP_CONFIG" >&2
fi

LOG_DIR="${CLAUDE_BACKUP_LOG_DIR:-$HOME/Library/Logs/claude-backup}"
mkdir -p "$LOG_DIR"
LOG_DRIVE="$LOG_DIR/rclone.log"
LOG_GIT="$LOG_DIR/git-snapshot.log"
LOG_DRIVE_LAUNCHD="$LOG_DIR/launchd-rclone.log"
LOG_GIT_LAUNCHD="$LOG_DIR/launchd-git-snapshot.log"
FLAG="$SCRIPT_DIR/.drift-status"
USER_NAME="$(id -un)"
# Per-layer throttle state for failure alerting (machine-local, not in repo).
ALERT_STATE_RCLONE="$LOG_DIR/.rclone-alert-state"
ALERT_STATE_GIT="$LOG_DIR/.git-snapshot-alert-state"
# Per-layer execution-lock directories (machine-local, not in repo).
LOCK_DRIVE="$LOG_DIR/.rclone.lock"
LOCK_GIT="$LOG_DIR/.git-snapshot.lock"

# Git operations always run against the ~/.claude tree.
cd "$HOME/.claude"

# --- execution lock --------------------------------------------------------
# A manual run and the launchd-scheduled run must not execute the same layer
# concurrently (overlapping rclone syncs waste bandwidth and interleave the
# log, corrupting the stats cmd_status parses). macOS ships no flock(1), so
# the lock is a directory: mkdir is atomic and fails if the directory exists.
# The holder PID is stored inside so a stale lock from a dead process can be
# reclaimed automatically.

# Acquire the lock for a layer. Returns 0 if acquired, 1 if a live process
# already holds it. The caller must pair this with lock_release.
lock_acquire() {
  local lock_dir="$1"
  if mkdir "$lock_dir" 2>/dev/null; then
    echo $$ > "$lock_dir/pid"
    return 0
  fi
  # Directory exists — is the holder still alive?
  local holder
  holder=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    return 1   # held by a live process
  fi
  # Stale lock (holder gone, or pid file missing/corrupt) — reclaim it.
  rm -rf "$lock_dir"
  if mkdir "$lock_dir" 2>/dev/null; then
    echo $$ > "$lock_dir/pid"
    return 0
  fi
  return 1   # lost a race to reclaim — treat as held
}

# Release the lock, but only if this process owns it.
lock_release() {
  local lock_dir="$1" holder
  holder=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  if [ "$holder" = "$$" ]; then
    rm -rf "$lock_dir"
  fi
}

# --- drive: rclone sync to Google Drive ------------------------------------
cmd_drive() {
  if ! lock_acquire "$LOCK_DRIVE"; then
    echo "$(date '+%F %T') SKIP: already running" >> "$LOG_DRIVE"
    return 0
  fi
  trap 'lock_release "$LOCK_DRIVE"' RETURN

  if ! curl -s --max-time 5 https://www.googleapis.com > /dev/null 2>&1; then
    echo "$(date '+%F %T') SKIP: no network" >> "$LOG_DRIVE"
    return 0
  fi
  local DATE rc=0
  DATE=$(date +%F)
  rclone sync "$HOME/.claude" "gdrive:backup/claude/latest" \
    --backup-dir "gdrive:backup/claude/${DATE}" \
    --exclude ".git/**" \
    --log-file "$LOG_DRIVE" \
    --log-level INFO || rc=$?

  if [ "$rc" -eq 0 ]; then
    # Explicit success marker. rclone's own end-of-run stats block carries no
    # timestamp, so this line is the only reliable last-success signal for
    # cmd_status. It also resets the failure-alert throttle streak.
    echo "$(date '+%F %T') OK: rclone sync complete" >> "$LOG_DRIVE"
    rm -f "$ALERT_STATE_RCLONE"
  else
    echo "$(date '+%F %T') FAIL: rclone sync exited $rc" >> "$LOG_DRIVE"
    drive_alert "$rc"
  fi
  return "$rc"
}

# --- failure alerting -------------------------------------------------------
# The alert machinery is shared by every backup layer. A thin per-layer wrapper
# (drive_alert / git_alert) gathers that layer's failure count and summary line,
# then hands off to the generic backup_alert.

# rclone-layer failure alert.
drive_alert() {
  local rc="$1" count detail
  count=$(awk '/ OK: rclone sync complete/{c=0} /CRITICAL:/{c++} END{print c+0}' "$LOG_DRIVE")
  detail=$(grep -E 'CRITICAL:|ERROR :' "$LOG_DRIVE" | tail -1 | cut -c1-200)
  if [ -z "$detail" ]; then
    detail="rclone sync exited $rc"
  fi
  backup_alert "Google Drive sync" "$ALERT_STATE_RCLONE" "$LOG_DRIVE" "$rc" "$count" "$detail"
}

# git-snapshot-layer failure alert.
git_alert() {
  local rc="$1" count
  count=$(awk '/ OK: /{c=0} / FAIL: /{c++} END{print c+0}' "$LOG_GIT")
  backup_alert "Git auto-snapshot" "$ALERT_STATE_GIT" "$LOG_GIT" "$rc" "$count" "git push exited $rc"
}

# Generic throttled failure alert for a backup layer.
# Throttle contract: fire on the first failure of a streak, then at most once
# per 24h while it continues. The state file holds the epoch seconds of the
# last alert sent; its absence means there is no active streak. Each layer's
# cmd_* clears its state file on success.
#   $1 label   human phrase, e.g. "Google Drive sync"
#   $2 state   throttle state file for this layer
#   $3 log     log file to excerpt into the email
#   $4 rc      exit code
#   $5 count   consecutive failure count
#   $6 detail  one-line summary for the desktop notification
backup_alert() {
  local label="$1" state="$2" log_file="$3" rc="$4" count="$5" detail="$6"
  local now last_alert
  now=$(date +%s)
  if [ -f "$state" ]; then
    last_alert=$(cat "$state" 2>/dev/null || echo 0)
    case "$last_alert" in
      ''|*[!0-9]*) last_alert=0 ;;
    esac
    if [ "$(( now - last_alert ))" -lt 86400 ]; then
      return 0    # already alerted within the last 24h — stay quiet
    fi
  fi
  echo "$now" > "$state"

  alert_notify "$label" "$count" "$detail"
  alert_email "$label" "$log_file" "$rc" "$count" "$detail"
}

# C1: macOS desktop notification.
alert_notify() {
  local label="$1" count="$2" detail="$3" body
  body=$(printf '%s consecutive failure(s). %s' "$count" "$detail" \
    | tr -d '"\\' | tr '\n' ' ' | cut -c1-220)
  osascript -e "display notification \"$body\" with title \"claude-backup\" subtitle \"$label failing\"" >/dev/null 2>&1 || true
}

# C2: email alert via Gmail SMTP (curl). Best-effort — any failure here is
# logged but never aborts the backup run. Credentials come from the
# machine-local config sourced at startup (see have_smtp_creds).
alert_email() {
  local label="$1" log_file="$2" rc="$3" count="$4" detail="$5"
  local to host subject sender smtp_pass excerpt msg

  if ! have_smtp_creds; then
    echo "$(date '+%F %T') ALERT: email skipped — SMTP credentials not configured" >> "$log_file"
    return 0
  fi
  to=$(find_alert_email) || {
    echo "$(date '+%F %T') ALERT: email skipped — no recipient configured" >> "$log_file"
    return 0
  }
  sender="$CLAUDE_BACKUP_SMTP_USER"
  # Gmail shows app passwords grouped with spaces; SMTP AUTH needs them removed.
  smtp_pass="${CLAUDE_BACKUP_SMTP_PASS// /}"
  host=$(hostname -s 2>/dev/null || echo "this Mac")
  subject="[claude-backup] $label FAILING ($count consecutive)"
  excerpt=$(tail -n 15 "$log_file" 2>/dev/null)

  # Compose with plain LF; the curl pipeline rewrites every line ending to the
  # CRLF that SMTP requires, so command substitution can't corrupt it.
  msg=$(printf '%s\n' \
    "From: claude-backup <$sender>" \
    "To: $to" \
    "Subject: $subject" \
    "Date: $(date '+%a, %d %b %Y %H:%M:%S %z')" \
    "Content-Type: text/plain; charset=utf-8" \
    "" \
    "A claude-backup layer is failing: $label" \
    "" \
    "Host: $host" \
    "Consecutive failures: $count" \
    "Last exit code: $rc" \
    "" \
    "Latest line:" \
    "  $detail" \
    "" \
    "Last 15 log lines ($log_file):" \
    "$excerpt" \
    "" \
    "Other backup layers are unaffected unless separately reported." \
    "Inspect:  claude-backup.sh status")

  if printf '%s\n' "$msg" | awk '{printf "%s\r\n", $0}' \
       | curl --silent --show-error --ssl-reqd \
         --url 'smtps://smtp.gmail.com:465' \
         --user "$sender:$smtp_pass" \
         --mail-from "$sender" \
         --mail-rcpt "$to" \
         --upload-file - >/dev/null 2>&1; then
    echo "$(date '+%F %T') ALERT: failure email sent" >> "$log_file"
  else
    echo "$(date '+%F %T') ALERT: failure email send failed" >> "$log_file"
  fi
}

# True when SMTP credentials are available. They are loaded by sourcing the
# machine-local config file at startup (see CLAUDE_BACKUP_CONFIG near the top);
# they may also be exported directly into the environment.
have_smtp_creds() {
  [ -n "${CLAUDE_BACKUP_SMTP_USER:-}" ] && [ -n "${CLAUDE_BACKUP_SMTP_PASS:-}" ]
}

# Resolve the alert recipient. Order: explicit override, then the Email line of
# ~/.claude/USER.md. Prints the address on success; returns 1 if none found.
find_alert_email() {
  if [ -n "${CLAUDE_BACKUP_ALERT_EMAIL:-}" ]; then
    printf '%s\n' "${CLAUDE_BACKUP_ALERT_EMAIL}"
    return 0
  fi
  local addr
  addr=$(grep -i 'email' "$HOME/.claude/USER.md" 2>/dev/null \
    | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
    | head -1)
  if [ -n "$addr" ]; then
    printf '%s\n' "$addr"
    return 0
  fi
  return 1
}

# --- git (no msg): diff-aware auto-snapshot to backup/auto -----------------
cmd_git_snapshot() {
  if ! lock_acquire "$LOCK_GIT"; then
    printf '%s SKIP: already running\n' "$(date '+%F %T')" >> "$LOG_GIT"
    return 0
  fi
  # One RETURN trap covers both the lock and the temp index. TMP_INDEX is
  # declared empty up front so the trap is safe to set before mktemp runs.
  local TMP_INDEX=""
  trap 'lock_release "$LOCK_GIT"; [ -z "$TMP_INDEX" ] || rm -f "$TMP_INDEX"' RETURN

  if ! curl -s --max-time 5 https://api.github.com > /dev/null 2>&1; then
    printf '%s SKIP: no network\n' "$(date '+%F %T')" >> "$LOG_GIT"
    return 0
  fi

  # Temp index — real .git/index is never modified.
  TMP_INDEX=$(mktemp /tmp/.claude-snapshot-index.XXXXXX)
  cp .git/index "$TMP_INDEX" 2>/dev/null || true
  export GIT_INDEX_FILE="$TMP_INDEX"

  git add -A
  local NEW_TREE LAST_TREE PARENT COMMIT GIT_RC=0
  NEW_TREE=$(git write-tree)
  LAST_TREE=$(git rev-parse --verify -q "refs/heads/backup/auto^{tree}" 2>/dev/null || echo "")

  if [ "$NEW_TREE" = "$LAST_TREE" ]; then
    printf '%s SKIP: no change\n' "$(date '+%F %T')" >> "$LOG_GIT"
  else
    PARENT=$(git rev-parse --verify -q refs/heads/backup/auto 2>/dev/null || git rev-parse main)
    COMMIT=$(printf 'auto: %s\n' "$(date '+%F %T %Z')" | git commit-tree "$NEW_TREE" -p "$PARENT")
    git update-ref refs/heads/backup/auto "$COMMIT"
    # Capture the push outcome so a failure can be logged and alerted rather
    # than aborting the run via set -e (which would skip the drift-flag update).
    git push origin "refs/heads/backup/auto:refs/heads/backup/auto" >> "$LOG_GIT" 2>&1 || GIT_RC=$?
    if [ "$GIT_RC" -eq 0 ]; then
      printf '%s OK: %s\n' "$(date '+%F %T')" "$COMMIT" >> "$LOG_GIT"
      rm -f "$ALERT_STATE_GIT"
    else
      printf '%s FAIL: git push exited %s\n' "$(date '+%F %T')" "$GIT_RC" >> "$LOG_GIT"
      git_alert "$GIT_RC"
    fi
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

  # Propagate a push failure so launchd records a non-zero exit.
  return "$GIT_RC"
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
    grep -E 'OK:|SKIP:|FAIL:' "$LOG_GIT" | tail -3 | sed 's/^/    /'
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
    local last_activity last_ok ok_stamp last_ok_ts now days
    local fail_count fail_since verdict fails skips
    # Match both rclone's own "YYYY/MM/DD" lines and our "YYYY-MM-DD" markers.
    last_activity=$(grep -oE '^[0-9]{4}[/-][0-9]{2}[/-][0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_DRIVE" | tail -1)
    last_ok=$(grep ' OK: rclone sync complete' "$LOG_DRIVE" | tail -1)
    # Consecutive CRITICAL failures since the last successful sync.
    fail_count=$(awk '/ OK: rclone sync complete/{c=0} /CRITICAL:/{c++} END{print c+0}' "$LOG_DRIVE")
    fail_since=$(awk '/ OK: rclone sync complete/{s=""} /CRITICAL:/{if(s=="")s=$1" "$2} END{print s}' "$LOG_DRIVE")

    if [ "$fail_count" -gt 0 ]; then
      verdict="FAILING — $fail_count consecutive failure(s)"
      if [ -n "$fail_since" ]; then
        verdict="$verdict since $fail_since"
      fi
    elif [ -n "$last_ok" ]; then
      verdict="HEALTHY"
    else
      verdict="UNKNOWN — no success or failure recorded yet"
    fi
    echo "  verdict: $verdict"

    if [ -n "$last_ok" ]; then
      ok_stamp=$(echo "$last_ok" | awk '{print $1" "$2}')
      last_ok_ts=$(date -j -f '%Y-%m-%d %H:%M:%S' "$ok_stamp" +%s 2>/dev/null || echo "")
      if [ -n "$last_ok_ts" ]; then
        now=$(date +%s)
        days=$(( (now - last_ok_ts) / 86400 ))
        echo "  last success: $ok_stamp (${days}d ago)"
      else
        echo "  last success: $ok_stamp"
      fi
    else
      echo "  last success: (none recorded)"
    fi

    echo "  last activity: ${last_activity:-(none)}"

    fails=$(grep -E 'CRITICAL:|ERROR :' "$LOG_DRIVE" | tail -3)
    if [ -n "$fails" ]; then
      echo "  recent errors:"
      printf '%s\n' "$fails" | cut -c1-150 | sed 's/^/    /'
    fi
    skips=$(grep 'SKIP:' "$LOG_DRIVE" | tail -2)
    if [ -n "$skips" ]; then
      echo "  recent SKIP:"
      printf '%s\n' "$skips" | sed 's/^/    /'
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
