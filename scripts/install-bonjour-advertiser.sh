#!/bin/bash
# Keep this Mac advertising the trm Bonjour service (_trm._tcp) even when
# trm.app is not running.
#
# trm itself advertises only while the app is open. This installs a per-user
# LaunchAgent that registers the service with `dns-sd -R` and keeps it
# registered (launchd restarts it if it dies), so other machines' remote-pane
# pickers always see this Mac. Like the in-app advertisement, nothing is
# served on the advertised port — remote panes connect over plain SSH.
#
# The instance name registered is this machine's "<LocalHostName>.local",
# which trm's discovery resolves as the SSH destination directly. When the
# app is also running, its own sharing-name advertisement resolves to the
# same hostname; trm (0.3.0+) dedupes the two into a single entry.
#
# Usage:
#   scripts/install-bonjour-advertiser.sh [ssh-port]     # install + start
#   scripts/install-bonjour-advertiser.sh --uninstall    # remove
#
# A user LaunchAgent starts at login; on a Mac that isn't always logged in,
# create the equivalent LaunchDaemon in /Library/LaunchDaemons instead.

set -euo pipefail

LABEL="com.trm.bonjour-advertise"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL."
  exit 0
fi

SSH_PORT="${1:-22}"
NAME="$(scutil --get LocalHostName).local"
# Advertise the account to log in as: machines don't share usernames, and a
# bare hostname makes a connecting ssh guess with ITS machine's username.
SSH_USER="$(id -un)"
# Advertise the tailnet address too. Bonjour only crosses one network, but the
# pane it creates outlives that network — a `.local` name is dead the moment
# the laptop leaves the house, while this keeps working. Read off the
# interfaces (Tailscale uses 100.64.0.0/10) so no CLI has to be installed.
TS_HOST="$(ifconfig 2>/dev/null | awk '/inet 100\./ { split($2, o, "."); if (o[2] >= 64 && o[2] <= 127) { print $2; exit } }')"
TS_ENTRY=""
if [ -n "$TS_HOST" ]; then
  TS_ENTRY="    <string>ts_host=$TS_HOST</string>"
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/dns-sd</string>
    <string>-R</string>
    <string>$NAME</string>
    <string>_trm._tcp</string>
    <string>local</string>
    <string>$SSH_PORT</string>
    <string>ssh_port=$SSH_PORT</string>
    <string>ssh_user=$SSH_USER</string>
$TS_ENTRY
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

# Reload cleanly whether or not a previous version is running.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Advertising $NAME on _trm._tcp (ssh_port=$SSH_PORT, ssh_user=$SSH_USER${TS_HOST:+, ts_host=$TS_HOST}), kept alive by launchd."
if [ -z "$TS_HOST" ]; then
  echo "No tailnet address found — panes made from this machine will use $NAME,"
  echo "which only resolves on this network. Re-run this once Tailscale is up."
fi
echo "Verify from another Mac:  dns-sd -B _trm._tcp local"
