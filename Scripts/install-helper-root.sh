#!/bin/bash
# Installs the FanBar root helper. Must run as root (the app calls it through
# osascript's administrator prompt; the CLI wraps it with sudo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="/Library/LaunchDaemons/local.fanbar.helper.plist"
TARGET="/Library/PrivilegedHelperTools/fanbar-helper"
SOCKET="/var/run/fanbar.helper.sock"

if [ "$(id -u)" -ne 0 ]; then
    echo "install-helper-root.sh must run as root" >&2
    exit 1
fi

if [ -n "${HELPER_BINARY:-}" ]; then
    HELPER="$HELPER_BINARY"
elif [ -x "$SCRIPT_DIR/../MacOS/fanbar-helper" ]; then
    HELPER="$SCRIPT_DIR/../MacOS/fanbar-helper"          # inside FanBar.app
elif [ -x "$SCRIPT_DIR/../../build/FanBar.app/Contents/MacOS/fanbar-helper" ]; then
    HELPER="$SCRIPT_DIR/../../build/FanBar.app/Contents/MacOS/fanbar-helper"
else
    echo "Cannot find fanbar-helper; run Scripts/build-app.sh first" >&2
    exit 1
fi

PLIST_TMP="$(mktemp -t fanbar.helper)"
trap 'rm -f "$PLIST_TMP"' EXIT
cat > "$PLIST_TMP" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.fanbar.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/fanbar-helper</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/fanbar-helper.log</string>
</dict>
</plist>
EOF

mkdir -p /Library/PrivilegedHelperTools
cp "$HELPER" "$TARGET"
chown root:wheel "$TARGET"
chmod 755 "$TARGET"
cp "$PLIST_TMP" "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

for _ in $(seq 1 10); do
    [ -S "$SOCKET" ] && break
    sleep 0.5
done
if [ -S "$SOCKET" ]; then
    echo "FanBar helper installed and ready."
else
    echo "FanBar helper installed but the socket is missing; check /var/log/fanbar-helper.log" >&2
    exit 1
fi
