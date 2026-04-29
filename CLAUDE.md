## Authority
This file is the source of truth for AI agent behavior in this repo. When rules conflict with the user's global `~/.claude/CLAUDE.md`, the global file wins (per its own authority rule).

## Architecture
Three-layer backup dispatcher: git `main` (semantic) + git `backup/auto` (auto-snapshot) + rclone (Google Drive mirror). See [SPEC.md](SPEC.md) for full architecture, subcommand specs, drift-flag contract, and design rationale.

## Run / Setup
- Install: `./setup.sh` — idempotent; renders plist templates into `~/Library/LaunchAgents/` and bootstraps launchd jobs.
- Manual: `./claude-backup.sh {drive|git|status}` or `./claude-backup.sh git "<msg>" [files...]`.
- Verify: `./claude-backup.sh status`.

## Code Style
- Shell scripts use bash with `set -e` (dispatcher) or `set -euo pipefail` (setup). Comments in English.
- POSIX-leaning where possible; bash-specific syntax fine where needed.
- No silent destructive operations — `cmd_git_commit` refuses to run if HEAD is not `main`.

## Templates
- Plist templates in `templates/` use placeholders `__HOME__`, `__USERNAME__`, `__SCRIPT_DIR__`, `__LOG_DIR__`. They MUST stay generic — never bake in user-specific paths.
- `setup.sh` renders templates with `sed` and writes directly to `~/Library/LaunchAgents/`. Rendered output is **not** symlinked back into the repo.

## Logs / State
- Logs: `$HOME/Library/Logs/claude-backup/` (not in repo). Override via `CLAUDE_BACKUP_LOG_DIR` env var.
- Drift flag: `<repo>/.drift-status` (gitignored). Consumed externally by `claude-statusline`. See SPEC.md "Drift Flag Contract".
- Never delete logs without explicit user approval.

## Doc Set
Three documents per the user's `/commit` skill convention:
- `README.md` — human-readable: project intro, quick start, command list.
- `CLAUDE.md` (this file) — AI agent index, ≤ 200 lines, mostly pointers.
- `SPEC.md` — AI-readable architecture & feature spec.
Always update all three together when behavior or interface changes.

## Doc Language
All docs in English. Code comments in English. The user's conversation language may be Traditional Chinese, but commits and docs stay English (LLM tokenizer efficiency + global readability for a public repo).

## Commits
- Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, etc.).
- One commit per logical change.
- Never commit automatically — present a summary and wait for explicit user approval.
- Never push without approval.

## Backwards Compatibility
- The path `~/.claude/system/backup/` may be a symlink pointing here. The dispatcher resolves `SCRIPT_DIR` to the real path, so the drift flag and any relative reads work consistently regardless of which path the script was invoked through.
- Do NOT introduce hardcoded `~/.claude/system/backup/...` references in this repo's code — keep `SCRIPT_DIR`-relative.

## launchd Operational Notes
- Always `bootout` before `bootstrap` when reloading; `setup.sh` does this for you.
- Job state can be inspected via `launchctl list | grep "com\.$(id -un)\.claude-"` or `launchctl print "gui/$(id -u)/<label>"`.
- Both jobs probe network and SKIP gracefully when offline; this is by design, not a bug to "fix".
