#!/bin/bash
set -e

if [ "$EUID" -eq 0 ]; then
    echo "Please run as your normal user instead of root!"
    exit 1
fi

REPO="sunshinekitsune/frame-arrpc-bridge"
RAW_URL="https://raw.githubusercontent.com/$REPO/main/frame"

DIR="$HOME/.local/share/frame-arrpc-bridge"
UNIT_DIR="$HOME/.config/systemd/user"

# Make sure to reach systemd user bus
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && [ -e "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

if [ -f "$DIR/uninstall.sh" ]; then
    echo "==> Existing installation found. Cleaning up prior version..."
    "$DIR/uninstall.sh" || true
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

if [ -f "frame-arrpc-bridge" ] && [ -f "systemd/frame-arrpc-bridge.service" ] && [ -f "uninstall.sh" ]; then
    # Local files
    echo "==> Installing from local files..."
    cp frame-arrpc-bridge "$TMP_DIR/"
    cp uninstall.sh "$TMP_DIR/"
    cp systemd/frame-arrpc-bridge.service "$TMP_DIR/"
else
    # Repo files
    echo "==> Installing from remote repository files..."
    TAG=$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")")
    if [ -z "$TAG" ]; then
        echo "Error: Could not determine latest release tag from GitHub."
        exit 1
    fi
    curl -fsSL "https://github.com/$REPO/releases/download/${TAG}/frame-arrpc-bridge" -o "$TMP_DIR/frame-arrpc-bridge"
    curl -fsSL "$RAW_URL/uninstall.sh" -o "$TMP_DIR/uninstall.sh"
    curl -fsSL "$RAW_URL/systemd/frame-arrpc-bridge.service" -o "$TMP_DIR/frame-arrpc-bridge.service"
fi

mkdir -p "$DIR/bin" "$UNIT_DIR"
install -m 755 "$TMP_DIR/frame-arrpc-bridge" "$DIR/bin/frame-arrpc-bridge"
install -m 755 "$TMP_DIR/uninstall.sh" "$DIR/uninstall.sh"
install -m 644 "$TMP_DIR/frame-arrpc-bridge.service" "$UNIT_DIR/frame-arrpc-bridge.service"

echo ""
echo "==> Registering systemd user service..."
systemctl --user daemon-reload
systemctl --user enable --now frame-arrpc-bridge.service

echo ""
echo "==> frame-arrpc-bridge is now installed and active."
echo "    Make sure you have an arRPC server running on your remote PC."
echo ""
echo "    View logs: journalctl --user -u frame-arrpc-bridge.service -f"
echo "    Uninstall: $DIR/uninstall.sh"