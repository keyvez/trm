#!/bin/bash
# Install trm CLI wrapper.
#
# Creates a `trm` command in /usr/local/bin that launches the trm macOS app.
# The app must be installed to /Applications/Ghostty.app (the default Xcode
# build output, renamed or copied).

set -e

APP_NAME="Ghostty"
CLI_NAME="trm"
INSTALL_DIR="/usr/local/bin"

# Find the app bundle — check common locations
APP_PATH=""
for candidate in \
    "/Applications/${APP_NAME}.app" \
    "$HOME/Applications/${APP_NAME}.app" \
    "$(dirname "$0")/../macos/build/ReleaseLocal/${APP_NAME}.app" \
    "$(dirname "$0")/../macos/build/Debug/${APP_NAME}.app"; do
    if [ -d "$candidate" ]; then
        APP_PATH="$candidate"
        break
    fi
done

if [ -z "$APP_PATH" ]; then
    echo "Error: Could not find ${APP_NAME}.app"
    echo "Build with: zig build -Doptimize=ReleaseFast"
    echo "Then copy macos/build/ReleaseLocal/${APP_NAME}.app to /Applications/"
    exit 1
fi

echo "Found app: $APP_PATH"

# Create the CLI wrapper
WRAPPER="$INSTALL_DIR/$CLI_NAME"
echo "Installing CLI wrapper to $WRAPPER ..."

sudo tee "$WRAPPER" > /dev/null << SCRIPT
#!/bin/bash
open -a "$APP_PATH" "\$@"
SCRIPT

sudo chmod +x "$WRAPPER"

echo "Done! You can now run: $CLI_NAME"
