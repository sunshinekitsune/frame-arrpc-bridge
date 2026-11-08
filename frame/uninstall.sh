#!/usr/bin/env bash
# Uninstall frame-arrpc-bridge. Keeps your config unless you pass --purge.
set -eu

NAME="frame-arrpc-bridge"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

if [ "$(id -u)" -eq 0 ]; then
    echo "Please run as your normal user instead of root!" >&2
    exit 1
fi

echo ""
PURGE=0
read -p "Do you want to purge configuration files? (y/N): " response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    PURGE=1
fi

# real systemd
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

echo ""
echo "==> Stopping and disabling $NAME.service..."
systemctl --user disable --now "$NAME.service" 2>/dev/null || true

rm -f "$CONFIG_HOME/systemd/user/$NAME.service"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user reset-failed "$NAME.service" 2>/dev/null || true

echo "==> Removing application files..."
rm -rf "$HOME/.local/share/$NAME"

if [ "$PURGE" -eq 1 ]; then
    echo "==> Removing config..."
    rm -rf "$CONFIG_HOME/$NAME"
fi

echo ""
echo "==> $NAME has been uninstalled."
if [ "$PURGE" -eq 0 ] && [ -d "$CONFIG_HOME/$NAME" ]; then
    echo "    Your config was kept at $CONFIG_HOME/$NAME (use --purge to remove it)."
fi
