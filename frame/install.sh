#!/usr/bin/env bash
set -euo pipefail

# LOCAL_BINARY=../zig-out/bin/frame-arrpc-bridge ./install.sh

REPO="sunshinekitsune/frame-arrpc-bridge"
NAME="frame-arrpc-bridge"

APP_DIR="$HOME/.local/share/$NAME"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$CONFIG_HOME/$NAME"
UNIT_DIR="$CONFIG_HOME/systemd/user"

die() {
    echo "Error: $*" >&2
    exit 1
}

[ "$(id -u)" -ne 0 ] || die "Please run as your normal user instead of root!"

# Always talk to the real systemd user session. On the Steam Frame, terminals opened
# in desktop mode run inside a nested Plasma session whose XDG_RUNTIME_DIR and
# DBUS_SESSION_BUS_ADDRESS point somewhere else, which makes `systemctl --user` fail.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi
systemctl --user show-environment >/dev/null 2>&1 ||
    die "Can't reach the systemd user session. Run this from a normal login session on the device."

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo ""
if [ -n "${LOCAL_BINARY:-}" ]; then
    echo "==> Installing from local files..."
    SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
    cp "$LOCAL_BINARY" "$TMP_DIR/$NAME"
    cp "$SRC_DIR/uninstall.sh" "$TMP_DIR/uninstall.sh"
    cp "$SRC_DIR/systemd/$NAME.service" "$TMP_DIR/$NAME.service"
else
    ASSET="$NAME-aarch64-linux"
    BASE="https://github.com/$REPO/releases/latest/download"

    echo "==> Downloading latest release ($ARCH)..."
    for f in "$ASSET" uninstall.sh "$NAME.service" SHA256SUMS; do
        curl -fsSL "$BASE/$f" -o "$TMP_DIR/$f" || die "Failed to download $f"
    done

    echo "==> Verifying checksums..."
    (cd "$TMP_DIR" && sha256sum --ignore-missing --quiet -c SHA256SUMS) ||
        die "Checksum verification failed"
    mv "$TMP_DIR/$ASSET" "$TMP_DIR/$NAME"
fi

echo "==> Installing files..."
systemctl --user stop "$NAME.service" 2>/dev/null || true

mkdir -p "$APP_DIR/bin" "$UNIT_DIR" "$CONFIG_DIR"
install -m 755 "$TMP_DIR/$NAME" "$APP_DIR/bin/$NAME"
install -m 755 "$TMP_DIR/uninstall.sh" "$APP_DIR/uninstall.sh"
install -m 644 "$TMP_DIR/$NAME.service" "$UNIT_DIR/$NAME.service"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    cat >"$CONFIG_DIR/config.json" <<'EOF'
{
    "port": 1337
}
EOF
fi

echo "==> Registering systemd user service..."
systemctl --user daemon-reload
systemctl --user enable "$NAME.service"
systemctl --user restart "$NAME.service"

sleep 1
if ! systemctl --user is-active --quiet "$NAME.service"; then
    echo "" >&2
    echo "Installed, but the service failed to start. Check the logs:" >&2
    echo "    journalctl --user -u $NAME.service -e" >&2
    exit 1
fi

echo ""
echo "==> $NAME is installed and running."
echo "    Make sure you have an arRPC server running on your remote PC."
echo ""
echo "    Config:    $CONFIG_DIR/config.json  (restart the service after editing)"
echo ""
echo "    Logs:      journalctl --user -u $NAME.service -f"
echo ""
echo "    Update:    re-run installer."
echo "    Uninstall: $APP_DIR/uninstall.sh"
