#!/bin/bash
# CLI wrapper: one sudo prompt, then the root installer. Password is read from
# stdin (or interactively), piped to sudo once, and never stored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 0 ]; then
    read -r -s -p "Admin password: " PASSWORD
    echo
else
    IFS= read -r PASSWORD
fi
printf '%s\n' "$PASSWORD" | sudo -S -v >/dev/null 2>&1 || { echo "sudo failed"; exit 1; }
unset PASSWORD

sudo -n bash "$SCRIPT_DIR/install-helper-root.sh"
