#!/bin/sh
# Run haven-relay as an always-on macOS background service (launchd LaunchAgent).
# It starts at login and restarts if it ever exits — a true set-and-forget daemon, no
# need to keep any app open. Re-run this script any time to refresh the service.
#
#   sh setup-macos.sh                  # use the binary already on PATH / in ~/.local/bin
#   sh setup-macos.sh --link <code>    # first-time: attach to your circle, then daemonize
set -e

BIN="$(command -v haven-relay || echo "$HOME/.local/bin/haven-relay")"
if [ ! -x "$BIN" ]; then
  echo "haven-relay not found. Install it first:  curl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh"
  exit 1
fi

LABEL="com.haven.relay"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs"; mkdir -p "$LOGDIR" "$HOME/Library/LaunchAgents"

# First run: attach to a circle (saves link.json), then we daemonize the credential-free `run`.
if [ "$1" = "--link" ] && [ -n "$2" ]; then
  echo "▸ Attaching to your circle…"
  "$BIN" run --link "$2" &
  RPID=$!; sleep 3; kill "$RPID" 2>/dev/null || true
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOGDIR/haven-relay.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/haven-relay.log</string>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

echo "✓ haven-relay is now an always-on background service (starts at login)."
echo "  node id:  $("$BIN" id)"
echo "  logs:     $LOGDIR/haven-relay.log"
echo "  stop:     launchctl bootout gui/$(id -u)/$LABEL && rm \"$PLIST\""
echo
echo "Next: open Haven → Settings → Storage → “Connect a relay”, paste the node id above,"
echo "and your circle will use this Mac as its always-on mailbox."
