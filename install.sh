#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="MarzGuard"
DEFAULT_BRANCH="main"
DEFAULT_REPO_PLACEHOLDER="YrustPd/MarzGuard"
INSTALL_PREFIX_BIN="/usr/local/bin"
INSTALL_LIB_DIR="/usr/local/lib/marzguard"
CONFIG_PATH="/etc/marzguard.conf"
SERVICE_PATH="/lib/systemd/system/MarzGuard.service"
LOG_FILE="/var/log/marzguard.log"
RUNTIME_DIR="/var/lib/marzguard"
STATE_DIR="/run/marzguard"
LOGROTATE_PATH="/etc/logrotate.d/marzguard"

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

info() {
    echo "[INFO] $*"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This installer must be run as root. Re-run with sudo."
    fi
}

PKG_MANAGER=""
PKG_UPDATE_DONE=0

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        die "No supported package manager detected (apt, dnf, yum)."
    fi
}

pkg_update() {
    if (( PKG_UPDATE_DONE == 1 )); then
        return
    fi
    case $PKG_MANAGER in
        apt)
            info "Updating apt repositories"
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            ;;
        dnf)
            info "Refreshing dnf metadata"
            dnf makecache || true
            ;;
        yum)
            info "Refreshing yum metadata"
            yum makecache || true
            ;;
    esac
    PKG_UPDATE_DONE=1
}

pkg_install() {
    local packages=()
    mapfile -t packages < <(printf '%s\n' "$@")
    if ((${#packages[@]} == 0)); then
        return
    fi
    case $PKG_MANAGER in
        apt)
            pkg_update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            ;;
        dnf)
            pkg_update
            dnf install -y "${packages[@]}"
            ;;
        yum)
            pkg_update
            yum install -y "${packages[@]}"
            ;;
    esac
}

ensure_prereqs() {
    local missing=()
    local dep
    for dep in curl tar awk sed grep systemctl; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    if ((${#missing[@]} > 0)); then
        info "Installing prerequisites: ${missing[*]}"
        pkg_install "${missing[@]}"
    fi
}

install_docker_apt() {
    info "Installing Docker Engine via apt"
    pkg_install ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    local distro_id codename
    # shellcheck disable=SC1091
    distro_id=$(. /etc/os-release; printf %s "$ID")
    curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    codename=$(lsb_release -cs)
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" \
        /etc/apt/keyrings/docker.gpg \
        "$distro_id" \
        "$codename" \
        >/etc/apt/sources.list.d/docker.list
    PKG_UPDATE_DONE=0
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_dnf() {
    info "Installing Docker Engine via dnf"
    pkg_install dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_yum() {
    info "Installing Docker Engine via yum"
    pkg_install yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
    if command -v docker >/dev/null 2>&1; then
        info "Docker already installed"
        return 0
    fi
    info "Docker not detected; attempting installation"
    case $PKG_MANAGER in
        apt) install_docker_apt || true ;;
        dnf) install_docker_dnf || true ;;
        yum) install_docker_yum || true ;;
    esac
    if ! command -v docker >/dev/null 2>&1; then
        cat <<'ENDWARN'
[WARN] Docker installation did not complete successfully.
       Please install Docker manually using the official instructions:
       https://docs.docker.com/engine/install/
ENDWARN
        return 1
    fi
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    return 0
}

STAGING_DIR=""
DOWNLOAD_DIR=""
BRANCH="$DEFAULT_BRANCH"
REQUESTED_REPO=""

parse_args() {
    while (($# > 0)); do
        case $1 in
            --repo)
                shift
                [[ $# -gt 0 ]] || die "--repo requires an argument"
                REQUESTED_REPO=$1
                ;;
            --branch)
                shift
                [[ $# -gt 0 ]] || die "--branch requires an argument"
                BRANCH=$1
                ;;
            --help|-h)
                cat <<'HELP'
Usage: install.sh [--repo owner/name] [--branch main]

Run as root. When executing via curl, pass --repo to specify the GitHub
repository to download if not running from a cloned checkout.
HELP
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
        shift || true
    done
}

cleanup() {
    if [[ -n $DOWNLOAD_DIR && -d $DOWNLOAD_DIR ]]; then
        rm -rf "$DOWNLOAD_DIR"
    fi
}

trap cleanup EXIT

resolve_source() {
    if [[ -d "$PWD/bin" && -f "$PWD/bin/MarzGuard" && -d "$PWD/lib" ]]; then
        STAGING_DIR="$PWD"
        info "Using local source directory $STAGING_DIR"
        return
    fi
    local repo="$REQUESTED_REPO"
    if [[ -z $repo ]]; then
        if [[ $DEFAULT_REPO_PLACEHOLDER == "CHANGE_ME/MarzGuard" ]]; then
            die "No source files found locally. Re-run with --repo owner/name to download."
        fi
        repo=$DEFAULT_REPO_PLACEHOLDER
    fi
    DOWNLOAD_DIR=$(mktemp -d)
    local tarball="https://codeload.github.com/$repo/tar.gz/$BRANCH"
    info "Downloading $tarball"
    if ! curl -fsSL "$tarball" -o "$DOWNLOAD_DIR/source.tar.gz"; then
        die "Failed to download repository archive"
    fi
    tar -xzf "$DOWNLOAD_DIR/source.tar.gz" -C "$DOWNLOAD_DIR"
    STAGING_DIR=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type d -name "*" ! -path "$DOWNLOAD_DIR" | head -n 1)
    if [[ -z $STAGING_DIR || ! -d $STAGING_DIR ]]; then
        die "Could not locate extracted repository contents"
    fi
    info "Staged source at $STAGING_DIR"
}

install_files() {
    install -m 0755 -d "$INSTALL_PREFIX_BIN"
    install -m 0755 "$STAGING_DIR/bin/MarzGuard" "$INSTALL_PREFIX_BIN/MarzGuard"

    install -m 0755 -d "$INSTALL_LIB_DIR"
    install -m 0644 "$STAGING_DIR/lib/marzguard-core.sh" "$INSTALL_LIB_DIR/marzguard-core.sh"

    install -m 0644 -D "$STAGING_DIR/packaging/MarzGuard.service" "$SERVICE_PATH"
    install -m 0644 -D "$STAGING_DIR/packaging/logrotate.d/marzguard" "$LOGROTATE_PATH"

    install -m 0755 -d "$RUNTIME_DIR"
    install -m 0755 -d "$STATE_DIR"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        install -m 0640 -D "$STAGING_DIR/etc/marzguard.conf" "$CONFIG_PATH"
    else
        install -m 0640 -D "$STAGING_DIR/etc/marzguard.conf" "$CONFIG_PATH.dist"
        info "Existing config retained. Updated defaults written to $CONFIG_PATH.dist"
    fi

    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
}

configure_service() {
    systemctl daemon-reload
    systemctl enable MarzGuard >/dev/null 2>&1 || true
    systemctl restart MarzGuard || systemctl start MarzGuard || true
}

print_summary() {
    cat <<END

$PROJECT_NAME installation complete.

Key locations:
  CLI:            $INSTALL_PREFIX_BIN/MarzGuard
  Config:         $CONFIG_PATH
  Service unit:   $SERVICE_PATH
  Log file:       $LOG_FILE

Next steps:
  1. Review configuration:   MarzGuard config
  2. Run self-test (mock):    MARZGUARD_MOCK=1 MarzGuard self-test
  3. Check status:            MarzGuard status
  4. Tail logs:               MarzGuard logs -f
END
}

main() {
    require_root
    parse_args "$@"
    detect_pkg_manager
    ensure_prereqs
    resolve_source
    ensure_docker || true
    install_files
    configure_service
    print_summary
}

main "$@"
