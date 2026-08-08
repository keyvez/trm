#!/bin/bash
# Reinstall trm.app into /Applications from a local build.
#
# Default source:
#   macos/build/ReleaseLocal/trm.app
#
# Optional source override:
#   scripts/reinstall-trm.sh /path/to/trm.app

set -euo pipefail

APP_DEST="/Applications/trm.app"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# xcodebuild with -derivedDataPath macos/build places the output under
# Build/Products/<config>/, while zig build uses the top-level directory.
XCODE_SRC="$REPO_ROOT/macos/build/Build/Products/ReleaseLocal/trm.app"
ZIG_SRC="$REPO_ROOT/macos/build/ReleaseLocal/trm.app"
if [[ -d "$XCODE_SRC" && -d "$ZIG_SRC" ]]; then
  # Prefer whichever was modified most recently.
  if [[ "$XCODE_SRC/Contents/MacOS/trm" -nt "$ZIG_SRC/Contents/MacOS/trm" ]]; then
    DEFAULT_SRC="$XCODE_SRC"
  else
    DEFAULT_SRC="$ZIG_SRC"
  fi
elif [[ -d "$XCODE_SRC" ]]; then
  DEFAULT_SRC="$XCODE_SRC"
else
  DEFAULT_SRC="$ZIG_SRC"
fi
APP_SRC="${1:-$DEFAULT_SRC}"

if [[ ! -d "$APP_SRC" ]]; then
  echo "Error: source app bundle not found: $APP_SRC"
  echo "Build first with: zig build -Doptimize=ReleaseFast"
  exit 1
fi

echo "Reinstalling trm:"
echo "  Source:      $APP_SRC"
echo "  Destination: $APP_DEST"

# Remove current app if present.
if [[ -d "$APP_DEST" ]]; then
  rm -rf "$APP_DEST"
fi

# Copy fresh app bundle.
cp -R "$APP_SRC" "$APP_DEST"

# Re-sign with a stable developer identity when one is available.
#
# The zig build ad-hoc signs the bundle, and ad-hoc signatures change on every
# rebuild — which invalidates the app's TCC grants (Accessibility, Screen
# Recording, Notifications) each time it is reinstalled. Signing with a real
# identity keeps the designated requirement stable so permissions survive.
SIGN_IDENTITY="${TRM_SIGN_IDENTITY:-Apple Development}"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DEST" 2>/dev/null; then
    echo "Re-signed with '$SIGN_IDENTITY' (stable TCC identity)."
  else
    echo "Warning: re-sign with '$SIGN_IDENTITY' failed; keeping ad-hoc signature."
  fi
fi

# Register the app so Finder/open use the latest bundle.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
fi

echo "Done."

# Refresh CLI wrapper too, so `trm` opens new windows with the current cwd.
INSTALL_CLI_SCRIPT="$(cd "$(dirname "$0")" && pwd)/install-cli.sh"
if [[ -x "$INSTALL_CLI_SCRIPT" ]]; then
  "$INSTALL_CLI_SCRIPT" || echo "Warning: failed to refresh CLI wrapper; run scripts/install-cli.sh manually."
fi
