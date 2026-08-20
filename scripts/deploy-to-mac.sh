#!/bin/bash
# Install a locally built trm.app onto another Mac over SSH, then sign it there
# with a stable identity.
#
#   scripts/deploy-to-mac.sh gaurav@100.125.56.90 [signing-identity]
#
# Why the two steps. A `zig build` produces an ad-hoc signed bundle, and an
# ad-hoc signature changes with every build — macOS ties privacy grants to the
# signature, so each install looks like a brand-new app and loses them. The one
# that hurts is Local Network: without it the Command Center server listens,
# accepts nothing from other devices, and the iPhone app times out with no
# error anywhere. Signing with a real identity keeps the grant.
#
# Signing needs the login keychain, which an SSH session cannot unlock, so the
# signing step is handed to the target's own login session via `open` — a
# Terminal window appears there with the result.
set -euo pipefail

DEST="${1:?usage: deploy-to-mac.sh user@host [signing-identity]}"
IDENTITY="${2:-Apple Development: Gaurav Misra (AC2TG9TNSG)}"
APP="$(cd "$(dirname "$0")/.." && pwd)/macos/build/ReleaseLocal/trm.app"

[ -x "$APP/Contents/MacOS/trm" ] || {
  echo "No build at $APP"
  echo "Build first:  zig build -Doptimize=ReleaseFast -Dxcframework-target=native"
  exit 1
}

echo "Shipping $(basename "$APP") to $DEST…"
tar -C "$(dirname "$APP")" -czf - "$(basename "$APP")" | ssh -o BatchMode=yes "$DEST" '
set -e
rm -rf /tmp/trm.app.new && mkdir -p /tmp/trm.app.new
tar -xzf - -C /tmp/trm.app.new
# Nothing touches /Applications until the new bundle is definitely unpacked:
# an interrupted transfer once left the target with no trm at all.
test -x /tmp/trm.app.new/trm.app/Contents/MacOS/trm
rm -rf /Applications/trm.app
mv /tmp/trm.app.new/trm.app /Applications/trm.app
rmdir /tmp/trm.app.new
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/trm.app >/dev/null 2>&1 || true
echo "installed"
'

echo "Signing on $DEST (a Terminal window will open there)…"
ssh -o BatchMode=yes "$DEST" "cat > /tmp/trm-resign.command" <<RESIGN
#!/bin/bash
exec > >(tee /tmp/trm-resign.log) 2>&1
codesign --force --deep --sign "$IDENTITY" /Applications/trm.app
STATUS=\$?
codesign -dv /Applications/trm.app 2>&1 | grep -E "Authority|TeamIdentifier" || true
[ \$STATUS -eq 0 ] && echo "TRM_RESIGN=ok" || echo "TRM_RESIGN=failed"
echo
echo "In trm: Cmd+Shift+R to relaunch into this build."
echo "Press Return to close."; read -r _
RESIGN
ssh -o BatchMode=yes "$DEST" 'chmod +x /tmp/trm-resign.command && rm -f /tmp/trm-resign.log && open /tmp/trm-resign.command'

for _ in $(seq 1 12); do
  RESULT="$(ssh -o BatchMode=yes "$DEST" 'grep -o "TRM_RESIGN=[a-z]*" /tmp/trm-resign.log 2>/dev/null | tail -1' || true)"
  [ -n "$RESULT" ] && { echo "$RESULT"; break; }
  sleep 5
done
echo "Done. Cmd+Shift+R on $DEST to pick it up."
