#!/bin/bash
# One-time, user-approved removal of Macs Fan Control (irreversible).
# Password is read from stdin (or interactively) and used only for sudo -v.
set -euo pipefail

if [ -t 0 ]; then
    read -r -s -p "Admin password: " PASSWORD
    echo
else
    IFS= read -r PASSWORD
fi
printf '%s\n' "$PASSWORD" | sudo -S -v >/dev/null 2>&1 || { echo "sudo failed"; exit 1; }
unset PASSWORD

echo "Quitting Macs Fan Control..."
killall "Macs Fan Control" 2>/dev/null || true

echo "Unloading its root helper..."
sudo -n launchctl bootout system /Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist 2>/dev/null || true

echo "Removing files..."
sudo -n rm -f /Library/LaunchDaemons/com.crystalidea.macsfancontrol.smcwrite.plist
sudo -n rm -f /Library/PrivilegedHelperTools/com.crystalidea.macsfancontrol.smcwrite
sudo -n rm -rf "/Applications/Macs Fan Control.app"
rm -f "$HOME/Library/Preferences/com.crystalidea.macsfancontrol.plist"

echo "Macs Fan Control removed. Install the FanBar helper from the menu to restore fan control."
