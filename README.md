# claude-backup

[![License](https://img.shields.io/github/license/howar31/claude-backup?style=flat-square)](LICENSE)
[![Built for Claude Code](https://img.shields.io/badge/built%20for-Claude%20Code-D77655?style=flat-square)](https://claude.com/claude-code)
[![Made with Bash](https://img.shields.io/badge/made%20with-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Conventional Commits](https://img.shields.io/badge/conventional%20commits-1.0.0-yellow?style=flat-square)](https://www.conventionalcommits.org)
[![GitHub Stars](https://img.shields.io/github/stars/howar31/claude-backup?style=flat-square)](https://github.com/howar31/claude-backup/stargazers)
[![Last Commit](https://img.shields.io/github/last-commit/howar31/claude-backup?style=flat-square)](https://github.com/howar31/claude-backup/commits/main)
[![Open Issues](https://img.shields.io/github/issues/howar31/claude-backup?style=flat-square)](https://github.com/howar31/claude-backup/issues)

Three-layer backup for a [Claude Code](https://claude.com/claude-code) config tree (`~/.claude` or equivalent), running as background launchd jobs on macOS.

```
~/.claude
   |
   |--- (1) git main           --> semantic history (LLM-synthesized commits)
   |--- (2) git backup/auto    --> append-only auto-snapshots, every 2h
   `--- (3) rclone             --> Google Drive mirror with daily snapshots, every 2h
```

The two git layers and the rclone layer split along a price/value axis: rclone is fast and total but has no history, git has history but is too costly for a 250MB+ tree of binary/log/db files. Splitting them is cheap and decoupled — and the two git branches deliberately diverge so `main` stays a clean human-readable timeline while `backup/auto` guarantees off-site git history is never more than 2 hours stale.

## Why three layers?

| Need | Layer | How it helps |
|------|-------|--------------|
| "I want to read what I changed last week" | git `main` | Conventional Commits, written manually with LLM help |
| "I never want to lose work between manual commits" | git `backup/auto` | Diff-aware snapshot every 2h, plumbing-only push that self-heals on divergence (won't disturb your working tree) |
| "I want my conversation logs and database recoverable" | rclone | Full mirror to Google Drive, plus dated folders for changed/deleted files |

## Quick Start

### 1. Install dependencies

```bash
brew install rclone gh
# rclone is required; gh is optional (only for repo management)
```

### 2. Clone this repo

```bash
git clone https://github.com/<owner>/claude-backup /opt/projects/claude-backup
```

(Path is up to you — anywhere works. The examples below use `/opt/projects/claude-backup`.)

### 3. Symlink for backwards compatibility (optional but recommended)

If you have any tooling that hardcodes `~/.claude/system/backup/...`, point it through a symlink so nothing breaks:

```bash
mkdir -p ~/.claude/system
ln -s /opt/projects/claude-backup ~/.claude/system/backup
```

### 4. Run setup

```bash
cd /opt/projects/claude-backup && ./setup.sh
```

This renders `templates/*.plist.template` with your `$HOME` / username / paths into `~/Library/LaunchAgents/`, then `bootstrap`s both jobs. Idempotent — safe to re-run after upgrades.

### 5. Configure rclone (one-time)

```bash
rclone config
# Create a remote named "gdrive" (type=drive, OAuth)
```

### 6. Verify

```bash
./claude-backup.sh status
launchctl list | grep "com\.$(id -un)\.claude-"
```

## Manual Operations

```bash
./claude-backup.sh status                    # three-layer health report
./claude-backup.sh drive                     # rclone -> Google Drive now
./claude-backup.sh git                       # auto-snapshot now (diff-aware, no-op if unchanged)
./claude-backup.sh git "feat: <msg>" [files] # semantic commit + push to main
```

## Schedule

| Job | Cadence | Subcommand |
|-----|---------|-----------|
| `com.<username>.claude-backup` | every 2h (00, 02, …, 22) | `drive` |
| `com.<username>.claude-git-snapshot` | every 2h (01, 03, …, 23) | `git` |

Git-snapshot ticks are offset by 1 hour from rclone to stagger I/O. Both subcommands probe network connectivity and SKIP gracefully when offline. launchd reruns missed jobs on wake. Each layer also holds an execution lock — if a scheduled tick fires while a manual run of the same layer is still going, it skips instead of starting a second copy.

## Failure Alerting

The unattended layers — rclone every 2h and the git auto-snapshot every 2h — can fail silently for days (most often an expired token). Two safeguards:

- **`status` verdict** — the `[rclone]` section reports an explicit `HEALTHY` / `FAILING` / `UNKNOWN` verdict, the last successful sync and its age, and the consecutive-failure count. The `[git backup/auto]` section surfaces recent `FAIL` lines.
- **Push alerts** — on a real failure of either layer, you get a macOS desktop notification and an email (the email includes the last 15 log lines). Alerts are throttled per layer: one when a failure streak starts, then at most once per 24h until the next success — so a multi-day outage never floods you.

A `SKIP` (no network, or nothing changed) is never treated as a failure.

### Configuration

Everything machine-specific — log location, alert recipient, SMTP credentials — lives in one file outside the repo, `~/.config/claude-backup/config`, so nothing sensitive is ever committed. The dispatcher sources it at startup; if it is absent, built-in defaults apply.

```bash
mkdir -p ~/.config/claude-backup
cat > ~/.config/claude-backup/config <<'EOF'
# Logs and alert-throttle state (default: ~/Library/Logs/claude-backup)
CLAUDE_BACKUP_LOG_DIR="$HOME/Library/Logs/claude-backup"

# Failure-alert recipient (falls back to the Email: line of ~/.claude/USER.md)
CLAUDE_BACKUP_ALERT_EMAIL="you@gmail.com"

# Gmail SMTP for email alerts (C2). SMTP_PASS is an app password, not your
# login password — create one at https://myaccount.google.com/apppasswords
# (the account needs 2-Step Verification). Leave SMTP_PASS empty to disable
# email alerts; the desktop notification still fires.
CLAUDE_BACKUP_SMTP_USER="you@gmail.com"
CLAUDE_BACKUP_SMTP_PASS=""
EOF
chmod 600 ~/.config/claude-backup/config
```

## Recovery

```bash
# git: pull a single file from a snapshot
git -C ~/.claude checkout backup/auto -- <path>

# git: list snapshots
git -C ~/.claude log backup/auto --format='%H %s' | head -20

# rclone: list dated snapshots
rclone lsd gdrive:backup/claude/

# rclone: restore a specific day
rclone copy gdrive:backup/claude/2026-04-23/path/to/file ./restored/

# rclone: restore everything to a sandbox
rclone copy gdrive:backup/claude/latest ~/.claude-restored/
```

## Files

| File | Purpose |
|------|---------|
| `claude-backup.sh` | Unified dispatcher (drive / git / status) |
| `setup.sh` | Idempotent installer |
| `templates/*.plist.template` | launchd schedules with placeholders |
| `SPEC.md` | Architecture spec for AI agents |
| `CLAUDE.md` | AI agent index for this repo |

Logs go to `$HOME/Library/Logs/claude-backup/`, not the repo.

## Statusline Integration

Pairs with [`claude-statusline`](https://github.com/howar31/claude-statusline). When git changes pile up (>5 unpushed files OR origin/main >3d behind), the dispatcher writes `.drift-status` to its directory; the statusline picks it up and renders a `⚠ N files / Nd behind` indicator on the same line as the timestamp. The indicator clears on the next successful manual `git "<msg>"` push.

## Documentation

- **[SPEC.md](SPEC.md)** — Architecture, subcommand specs, design rationale, recovery procedures
- **[CLAUDE.md](CLAUDE.md)** — Repo-local conventions for AI agents

## License

[MIT](LICENSE)
