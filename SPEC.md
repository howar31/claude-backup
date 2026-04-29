# claude-backup — Architecture Spec

AI-readable architecture & feature spec for future agents. For a human-friendly intro and quick start, see `README.md`. For repo-local conventions, see `CLAUDE.md`.

## Purpose

A three-layer backup harness for a Claude Code config tree (`~/.claude` or equivalent). Designed to keep large files mirrored off-site cheaply and config files in semantic version control, while requiring zero conscious user action between manual semantic commits.

## Three-Layer Model

| Layer | Content | Destination | Granularity | Trigger |
|-------|---------|-------------|-------------|---------|
| Git `main` | Semantic commits, tracked config only | `<your-config-repo>` | Per-commit | Manual (LLM-synthesized message) |
| Git `backup/auto` | Append-only work-tree snapshots, tracked config only | Same repo, separate branch | Per-snapshot (skips if tree unchanged) | launchd every 6h |
| rclone | Everything in the watched tree (logs, db, caches) | `gdrive:backup/claude/` | Daily snapshots via `--backup-dir` | launchd every 2h |

The two git branches deliberately diverge:
- `main` retains a human-readable timeline written by the user with LLM help.
- `backup/auto` exists purely so the off-site git history is never more than 6 hours stale, and so we never lose work to a forgotten commit.

## Component Overview

| File | Role |
|------|------|
| `claude-backup.sh` | Unified dispatcher with subcommands `drive` / `git` / `git "<msg>" [files...]` / `status` |
| `setup.sh` | Idempotent installer: dependency check, creates log dir, renders plist templates, loads launchd jobs |
| `templates/claude-backup.plist.template` | rclone schedule template with `__USERNAME__` / `__SCRIPT_DIR__` / `__LOG_DIR__` placeholders |
| `templates/claude-git-snapshot.plist.template` | git-snapshot schedule template, same placeholder set |
| `SPEC.md` | This file — architecture for AI agents |
| `README.md` | Human-facing intro and quick start |
| `CLAUDE.md` | AI agent index for this repo |
| `.drift-status` | Ephemeral flag (gitignored). Consumed by external statusline. |

Logs live outside the repo at `$HOME/Library/Logs/claude-backup/`.

## Data Flow

```
                                ~/.claude (or other watched tree)
                                          |
                       +------------------+------------------+
                       |                  |                  |
            cmd_git_commit         cmd_git_snapshot      cmd_drive
            (manual semantic)      (launchd 6h, isolated  (launchd 2h, rclone
                                    temp git index)        sync to Google Drive)
                       |                  |                  |
                       v                  v                  v
                   git main         git backup/auto      gdrive:backup/claude/
                                                          ├── latest/        (mirror)
                                                          └── YYYY-MM-DD/    (--backup-dir)
```

## Subcommand Specs

### `claude-backup.sh drive`

- Probe `https://www.googleapis.com` (5s timeout). If unreachable, append `SKIP: no network` to log and return 0.
- `rclone sync $HOME/.claude gdrive:backup/claude/latest --backup-dir gdrive:backup/claude/$(date +%F) --exclude ".git/**" --log-file "$LOG_DRIVE" --log-level INFO`.
- Excludes `.git/**` so rclone doesn't fight the git layer.
- `--backup-dir` semantics: when a file in `latest/` is overwritten or deleted, the prior version is moved to the dated folder. New files go directly to `latest/`. If nothing changed, no snapshot files are created.
- Remote name `gdrive:` is rclone-config-driven; user must `rclone config` once to authorize.

### `claude-backup.sh git` (no arguments — auto-snapshot)

Diff-aware append to `backup/auto`, completely isolated from the user's working state.

1. Network probe: `https://api.github.com`. SKIP+log if offline.
2. Copy `.git/index` to `mktemp /tmp/.claude-snapshot-index.XXXXXX`. Set `GIT_INDEX_FILE` to the temp copy. The real index is never modified.
3. `git add -A` against the temp index → `git write-tree` produces NEW_TREE.
4. Read `refs/heads/backup/auto^{tree}` as LAST_TREE.
5. If NEW_TREE = LAST_TREE: `SKIP: no change`, return.
6. Else: PARENT = previous `backup/auto` head, or `main` on first run.
7. `git commit-tree NEW_TREE -p PARENT` with message `auto: <ISO timestamp>` → COMMIT.
8. `git update-ref refs/heads/backup/auto COMMIT`.
9. `git push origin refs/heads/backup/auto:refs/heads/backup/auto` (fast-forward; never `--force`).
10. Drift flag update — see "Drift Flag Contract" below.

Key invariants:
- Plumbing only (`commit-tree`, `update-ref`, `write-tree`). No `checkout`, no `branch`, no `stash`, no working-tree mutation.
- Real `.git/index` untouched — whatever is staged for a manual commit stays staged.
- Append-only push — never rewrites history on `backup/auto`.

### `claude-backup.sh git "<msg>" [files...]`

Semantic commit on `main`.

1. Refuse if HEAD is not `main` (return 1, error message).
2. If files are passed, `git add -- <files>`. Otherwise `git add -A`.
3. If no staged diff, print `No staged changes — nothing to commit` and return 0.
4. `git commit -m "<msg>"` → `git push origin main`.
5. On success, `rm -f $FLAG` so the statusline updates immediately.

The dispatcher does not synthesize the commit message itself. The `/backup` skill (in the parent `~/.claude` repo) reads the diff with an LLM and supplies the message.

### `claude-backup.sh status`

Compact three-layer health report. Reads only — no writes, no network. Format:

```
[git main]            commit + ISO time + pending file count
[git backup/auto]     last commit + recent OK/SKIP lines from git-snapshot.log
[drift flag]          contents of FLAG file, or "synced"
[rclone]              last activity timestamp + recent SKIPs + Transferred/Errors/Elapsed stats
[launchd jobs]        pid / last-exit / state for both com.<user>.claude-* jobs
[launchd errors]      contents of any non-empty launchd-*.log
```

## Drift Flag Contract

The flag is the only piece of cross-repo state. Two parties touch it:

**Writer (this repo, in `cmd_git_snapshot`):**
- Computes `COUNT = git status --porcelain | wc -l`.
- Computes `DAYS_BEHIND = (now - origin/main last commit time) / 86400`.
- If `COUNT > 5 || DAYS_BEHIND > 3`: write `<COUNT> files / <DAYS_BEHIND>d behind` to `$FLAG`.
- Else: `rm -f $FLAG`.

**Cleared on:** successful manual `cmd_git_commit` push (so the statusline updates immediately, not waiting for the next 6h tick).

**Reader (external — `claude-statusline`):**
- Path: `~/.claude/system/backup/.drift-status` (resolves through the symlink to `<repo>/.drift-status`).
- Behavior: if file exists, append ` · ⚠ <contents>` to the timestamp line. Same line — line count stays constant so the statusline never jumps between renders.

Freshness bound: `min(6h since last snapshot tick, time since manual push)`.

The flag is `.gitignore`'d in this repo (machine-local ephemeral state).

## File-Layout Contract

This repo lives at `<arbitrary path>` (default suggestion: `/opt/projects/claude-backup`). For backwards compatibility with tools that hardcode `~/.claude/system/backup/...`, install a symlink:

```
~/.claude/system/backup -> /opt/projects/claude-backup
```

After the symlink:
- `~/.claude/system/backup/claude-backup.sh` resolves correctly.
- `~/.claude/system/backup/.drift-status` resolves to `<repo>/.drift-status`.
- All existing references in third-party tooling continue to work without modification.

The dispatcher uses `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`, which resolves to the actual physical path (after the symlink), so the drift flag is written to and read from the same physical file regardless of which path the script was invoked through.

## launchd Schedule

Two jobs, registered in `$HOME/Library/LaunchAgents/`:

| Label (rendered) | Cadence (StartCalendarInterval) | Subcommand |
|------------------|--------------------------------|-----------|
| `com.<username>.claude-backup` | every 2h: 00, 02, 04, 06, 08, 10, 12, 14, 16, 18, 20, 22 | `drive` |
| `com.<username>.claude-git-snapshot` | every 6h: 01, 07, 13, 19 (offset by 1h to stagger I/O) | `git` |

**Sleep handling:** launchd runs missed jobs on wake.
**Network failure:** Both subcommands probe connectivity and SKIP+log gracefully.

## Plist Templating

Templates live in `templates/*.plist.template` with placeholders:
- `__HOME__` → `$HOME` of installing user
- `__USERNAME__` → `$(id -un)` (used for both Label and the LaunchAgent filename)
- `__SCRIPT_DIR__` → physical path to this repo (`$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` from `setup.sh`)
- `__LOG_DIR__` → `$HOME/Library/Logs/claude-backup`

`setup.sh` renders templates with `sed` and writes directly to `$HOME/Library/LaunchAgents/com.<username>.<name>.plist`. The rendered plist is **not** symlinked back into the repo — it contains user-specific paths and stays under the user's `~/Library/`.

Re-running `setup.sh` is safe: the script `bootout`s any existing job with the same Label before `bootstrap`-ing the freshly rendered plist.

## Log Layout

All logs live at `$HOME/Library/Logs/claude-backup/` (overridable via `CLAUDE_BACKUP_LOG_DIR` env var).

| File | Writer | Content |
|------|--------|---------|
| `rclone.log` | `cmd_drive` (rclone `--log-file`) | Full rclone INFO output, plus `SKIP: no network` lines |
| `git-snapshot.log` | `cmd_git_snapshot` | One line per tick: `<ts> OK: <sha>` / `<ts> SKIP: no change` / `<ts> SKIP: no network`, plus push output on errors |
| `launchd-rclone.log` | launchd stdout/stderr redirect | Almost always empty; only populated on launchd-level failures |
| `launchd-git-snapshot.log` | launchd stdout/stderr redirect | Same |

Logs are intentionally outside the repo so they cannot accidentally be committed to the public mirror.

## Recovery Procedures

### From git `backup/auto`

```bash
# Diff main vs latest snapshot
git -C ~/.claude diff main backup/auto -- <path>

# Pull a single file from a snapshot
git -C ~/.claude checkout backup/auto -- <path>

# Find a specific snapshot timestamp
git -C ~/.claude log backup/auto --format='%H %s' | head -20
```

### From rclone

```bash
# Browse dated snapshots
rclone lsd gdrive:backup/claude/

# List a specific day
rclone ls gdrive:backup/claude/2026-04-23/

# Restore a single file from a specific day
rclone copy gdrive:backup/claude/2026-04-23/path/to/file ./restored/

# Restore full latest state to a sandbox dir
rclone copy gdrive:backup/claude/latest ~/.claude-restored/
```

### Full machine restore

```bash
# 1. Install tools
brew install rclone gh

# 2. Clone config repo (your private one)
git clone <your-config-repo> ~/.claude

# 3. Clone this backup repo and install
git clone https://github.com/<owner>/claude-backup /opt/projects/claude-backup
ln -s /opt/projects/claude-backup ~/.claude/system/backup
/opt/projects/claude-backup/setup.sh

# 4. Configure rclone Google Drive remote
rclone config
# Create remote named "gdrive" (type=drive, follow OAuth prompts)

# 5. Restore non-tracked large files (logs, db, etc.)
rclone copy gdrive:backup/claude/latest ~/.claude \
  --exclude ".git/**" \
  --ignore-existing

# 6. Verify
/opt/projects/claude-backup/claude-backup.sh status
launchctl list | grep "com\.$(id -un)\.claude-"
```

## Dependencies

| Tool | Required for | Install |
|------|--------------|---------|
| `git` | All git layers | `xcode-select --install` |
| `rclone` | drive layer | `brew install rclone` |
| `curl` | Network probes | macOS built-in |
| `gh` | (optional) GitHub CLI for repo management | `brew install gh` |

## Design Rationale

- **Why three layers?** rclone is fast and total but lacks history. Git has history but is too costly for a 250MB tree of which 245MB is binary/log/db. Splitting them along that axis is cheap and decoupled.
- **Why a separate `backup/auto` branch?** A single `main` would either accumulate noise commits (if auto-committed) or stale (if only manually committed). Splitting gives both: clean human history and bounded staleness.
- **Why `git commit-tree` plumbing?** A naive `git stash; git commit; git stash pop` would race with active editing sessions and risk losing work. Plumbing operates on a temp index and never touches `.git/index` or the working tree.
- **Why `--backup-dir` instead of versioned remotes?** It's the cheapest form of point-in-time recovery — only changed/deleted files cost storage. A new dated folder is created lazily and stays empty if nothing changed that day.
- **Why plist templates?** Hardcoding `/Users/<name>/...` in a public repo bakes the author's machine into every clone. Templates with `setup.sh` rendering keep the repo clean and let any user clone-and-run.
- **Why logs outside the repo?** Even with `.gitignore`, logs containing personal file paths represent an exfiltration risk if accidentally committed. Putting them under `$HOME/Library/Logs/` makes the boundary structural, not policy.
- **Why a symlink at `~/.claude/system/backup`?** Existing tooling (statusline drift reader, the `/backup` skill, prior plans, third-party scripts) has already encoded that path. The symlink preserves all of that for free.

## Statusline Integration

External: [`claude-statusline`](https://github.com/howar31/claude-statusline) reads `~/.claude/system/backup/.drift-status` and renders:

```
abc123 · 2026.04.28 13:00:00 · ⚠ 8 files / 2d behind
```

Same line as the timestamp. Line count stays constant whether drift exists or not, so the statusline never jumps between renders.

## Manual Operations Cheat Sheet

```bash
# Health
./claude-backup.sh status

# Manual one-shots
./claude-backup.sh drive                         # rclone now
./claude-backup.sh git                           # auto-snapshot now (diff-aware)
./claude-backup.sh git "feat: new skill"         # semantic commit + push main

# Inspect logs
tail -20 ~/Library/Logs/claude-backup/rclone.log
tail -20 ~/Library/Logs/claude-backup/git-snapshot.log

# launchd
launchctl list | grep "com\.$(id -un)\.claude-"
launchctl print "gui/$(id -u)/com.$(id -un).claude-backup" | head -40

# Reload after config change
./setup.sh                                        # re-renders + bootstraps both jobs
```
