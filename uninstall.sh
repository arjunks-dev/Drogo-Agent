#!/usr/bin/env bash
#
# RedTeam Agent — standalone uninstaller.
#
# Thin wrapper over `./setup.sh uninstall` so there is a single source of truth
# for the uninstall logic. It:
#   • stops + removes the Orchestrator systemd service
#   • removes the managed alias block from ~/.bashrc / ~/.zshrc
#   • asks whether to also remove the agent runtime dir (~/redteam-agent)
#   • finally asks whether to remove this installer source directory as well
#
# The run is logged to ./logs/uninstall-<timestamp>.log (same location as the
# install logs). If you choose to delete the source directory, the log is first
# copied to your home directory so it survives.
#
# Usage:
#   ./uninstall.sh
#
# Only for authorized security testing. See README / SETUP.md.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$DIR/setup.sh" ]; then
  echo "[x] setup.sh not found next to uninstall.sh ($DIR). Run this from the source directory." >&2
  exit 1
fi

exec bash "$DIR/setup.sh" uninstall "$@"
