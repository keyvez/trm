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

echo "Done! Run 'trm --help' for usage."
