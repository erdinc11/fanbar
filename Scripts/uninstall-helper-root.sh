#!/bin/bash
# Removes the FanBar root helper and returns the fan to macOS. Must run as root.
set -euo pipefail

PLIST="/Library/LaunchDaemons/local.fanbar.helper.plist"
TARGET="/Library/PrivilegedHelperTools/fanbar-helper"
SOCKET="/var/run/fanbar.helper.sock"

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall-helper-root.sh must run as root" >&2
    exit 1
fi

launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST" "$TARGET" "$SOCKET"
echo "FanBar helper removed."
