#!/bin/bash
# Install trm CLI.
#
# Installs the `trm` command to /usr/local/bin. The CLI supports subcommands
# for controlling the running trm app via the Text Tap Unix socket, and falls
# back to launching the app when invoked with no arguments.

set -e

CLI_NAME="trm"
INSTALL_DIR="/usr/local/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI_SOURCE="$SCRIPT_DIR/trm-cli.sh"

if [ ! -f "$CLI_SOURCE" ]; then
    echo "Error: trm-cli.sh not found at $CLI_SOURCE"
    exit 1
fi

echo "Installing $CLI_NAME CLI to $INSTALL_DIR/$CLI_NAME ..."
sudo cp "$CLI_SOURCE" "$INSTALL_DIR/$CLI_NAME"
sudo chmod +x "$INSTALL_DIR/$CLI_NAME"

# `trm mirror` / `trm attach-remote` resolve mirror-session.py next to the
# CLI first (fallback: app Resources), so install it alongside.
if [ -f "$SCRIPT_DIR/mirror-session.py" ]; then
    sudo cp "$SCRIPT_DIR/mirror-session.py" "$INSTALL_DIR/mirror-session.py"
    sudo chmod +x "$INSTALL_DIR/mirror-session.py"
fi

echo "Done! Run 'trm --help' for usage."
