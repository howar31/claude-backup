#!/bin/bash
# Thin wrapper that exec's the dispatcher with the `drive` subcommand.
# Exists so the macOS "Login Items & Extensions" UI — which shows the
# basename of ProgramArguments[0] — displays a distinct name per launchd
# job. All logic lives in claude-backup.sh.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/claude-backup.sh" drive
