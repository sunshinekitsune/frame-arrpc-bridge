#!/bin/bash

if [ "$EUID" -eq 0 ]; then
    echo "Please run as your normal user instead of root!"
    exit 1
fi

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && [ -e "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

echo "==> Stopping and disabling frame-arrpc-bridge.service..."
systemctl --user disable --now frame-arrpc-bridge.service 2>/dev/null || true

rm -f "$HOME/.config/systemd/user/frame-arrpc-bridge.service"
systemctl --user daemon-reload
systemctl --user reset-failed frame-arrpc-bridge.service 2>/dev/null || true

echo "==> Removing application files..."
rm -rf "$HOME/.local/share/frame-arrpc-bridge"

echo ""
echo "==> frame-arrpc-bridge has been uninstalled."