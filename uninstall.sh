#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="MarzGuard"
INSTALL_PREFIX_BIN="/usr/local/bin/MarzGuard"
INSTALL_LIB_DIR="/usr/local/lib/marzguard"
SERVICE_PATH="/lib/systemd/system/MarzGuard.service"
CONFIG_PATH="/etc/marzguard.conf"
CONFIG_DIST_PATH="/etc/marzguard.conf.dist"
LOG_FILE="/var/log/marzguard.log"
RUNTIME_DIR="/var/lib/marzguard"
STATE_DIR="/run/marzguard"
LOGROTATE_PATH="/etc/logrotate.d/marzguard"

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This uninstaller must be run as root. Re-run with sudo."
    fi
}

stop_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop MarzGuard >/dev/null 2>&1 || true
        systemctl disable MarzGuard >/dev/null 2>&1 || true
    fi
}

remove_files() {
    rm -f "$INSTALL_PREFIX_BIN"
    rm -f "$INSTALL_LIB_DIR/marzguard-core.sh"
    rmdir "$INSTALL_LIB_DIR" >/dev/null 2>&1 || true
    rm -f "$SERVICE_PATH"
    rm -f "$LOGROTATE_PATH"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

prompt_cleanup() {
    local response
    read -r -p "Remove configuration and logs? [y/N] " response
    case ${response:-N} in
        y|Y|yes|YES)
            rm -f "$CONFIG_PATH" "$CONFIG_DIST_PATH"
            rm -f "$LOG_FILE"
            rm -rf "$RUNTIME_DIR" "$STATE_DIR"
            echo "Configuration and logs removed."
            ;;
        *)
            echo "Configuration and logs preserved."
            ;;
    esac
}

main() {
    require_root
    stop_service
    remove_files
    prompt_cleanup
    echo "$PROJECT_NAME removed."
}

main "$@"
