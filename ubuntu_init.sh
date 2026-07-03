#!/usr/bin/env bash

set -euo pipefail

# Usage:
#   sudo ./ubuntu_init.sh
#   ./ubuntu_init.sh
#   curl -fsSL <url-to-this-script> | bash

readonly MIN_UBUNTU_MAJOR=24
readonly MIN_UBUNTU_MINOR=4
readonly DOCKER_DATA_ROOT="/data/docker"
readonly OS_RELEASE_PATH="${OS_RELEASE_FILE:-/etc/os-release}"
readonly SUDO_BIN="${SUDO_BIN:-sudo}"

TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""

die() {
  echo "$1" >&2
  exit 1
}

log_step() {
  printf '\n==> %s\n' "$1"
}

unsupported_os() {
  die "Error: This script is only supported on Ubuntu >= 24.04."
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

require_sudo() {
  if is_root; then
    return 0
  fi

  command -v "$SUDO_BIN" >/dev/null 2>&1 ||
    die "This script requires sudo."

  if "$SUDO_BIN" -n true 2>/dev/null; then
    return 0
  fi

  if [ -r /dev/tty ]; then
    "$SUDO_BIN" -v </dev/tty ||
      die "This script requires sudo privileges."
    return 0
  fi

  die "This script requires sudo privileges. Run it in a terminal or configure passwordless sudo."
}

run_as_root() {
  if is_root; then
    "$@"
  else
    "$SUDO_BIN" "$@"
  fi
}

write_root_file() {
  local path="$1"
  local mode="${2:-0644}"
  local tmp_file

  tmp_file="$(mktemp)"
  cat >"$tmp_file"
  run_as_root install -m "$mode" -D "$tmp_file" "$path"
  rm -f "$tmp_file"
}

read_os_release_value() {
  local key="$1"
  local file="$2"
  local line
  local value

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        printf '%s' "$value"
        return 0
        ;;
    esac
  done <"$file"

  return 1
}

version_at_least_minimum() {
  local version_id="$1"
  local version_major
  local version_minor

  version_major="${version_id%%.*}"
  version_minor="${version_id#*.}"
  if [ "$version_minor" = "$version_id" ]; then
    version_minor="0"
  else
    version_minor="${version_minor%%.*}"
  fi

  case "$version_major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$version_minor" in
    ''|*[!0-9]*) return 1 ;;
  esac

  version_major=$((10#$version_major))
  version_minor=$((10#$version_minor))

  if [ "$version_major" -gt "$MIN_UBUNTU_MAJOR" ]; then
    return 0
  fi

  if [ "$version_major" -eq "$MIN_UBUNTU_MAJOR" ] &&
    [ "$version_minor" -ge "$MIN_UBUNTU_MINOR" ]; then
    return 0
  fi

  return 1
}

require_supported_os() {
  local os_id
  local version_id

  [ -r "$OS_RELEASE_PATH" ] || unsupported_os

  os_id="$(read_os_release_value ID "$OS_RELEASE_PATH" || true)"
  version_id="$(read_os_release_value VERSION_ID "$OS_RELEASE_PATH" || true)"

  [ "$os_id" = "ubuntu" ] || unsupported_os
  version_at_least_minimum "$version_id" || unsupported_os
}

init_target_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
  else
    TARGET_USER="$(id -un)"
  fi

  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  TARGET_GROUP="$(id -gn "$TARGET_USER")"

  [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] ||
    die "Cannot determine home directory for $TARGET_USER."
}

install_common_tools() {
  local packages=(
    git
    vim
    curl
    wget
    htop
    atop
    iotop
    tmux
    mtr
    unzip
    zip
    zsh
    tree
    mosh
    jq
    build-essential
  )

  run_as_root apt update
  run_as_root apt install -y "${packages[@]}"
}

set_default_editor() {
  run_as_root update-alternatives --set editor /usr/bin/vim.basic
}

configure_docker() {
  run_as_root mkdir -p "$DOCKER_DATA_ROOT"
  write_root_file "/etc/docker/daemon.json" <<EOL
{
  "data-root": "$DOCKER_DATA_ROOT",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file":"5"
  }
}
EOL
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log_step "Docker is already installed; skipping installer"
  else
    wget -qO- get.docker.com | run_as_root bash
  fi

  run_as_root systemctl enable docker
  run_as_root systemctl restart docker
}

configure_vim() {
  write_root_file "/etc/vim/vimrc.local" <<EOL
filetype plugin indent on
" show existing tab with 4 spaces width
set tabstop=4
" when indenting with '>', use 4 spaces width
set shiftwidth=4
" On pressing tab, insert 4 spaces
set expandtab
EOL
}

configure_passwordless_sudo() {
  write_root_file "/etc/sudoers.d/sudo" "0440" <<EOL
%sudo ALL=(ALL) NOPASSWD: ALL
EOL
}

configure_journald() {
  write_root_file "/etc/systemd/journald.conf.d/00-journal-limit.conf" <<EOL
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=200M
MaxRetentionSec=14day
EOL
  run_as_root systemctl restart systemd-journal-flush.service
  run_as_root systemctl restart systemd-journald
}

configure_logrotate() {
  if run_as_root test -f /etc/logrotate.conf; then
    if ! run_as_root grep -q "maxsize" /etc/logrotate.conf; then
      run_as_root sed -i '/^# global options/a \    maxsize 1G' /etc/logrotate.conf
    fi
    run_as_root sed -i 's/#compress/compress/g' /etc/logrotate.conf
  fi
}

disable_apt_daily_timers() {
  run_as_root systemctl mask \
    apt-daily.service \
    apt-daily.timer \
    apt-daily-upgrade.service \
    apt-daily-upgrade.timer
}

disable_welcome_message() {
  if [ "$TARGET_USER" = "$(id -un)" ] && ! is_root; then
    touch "$TARGET_HOME/.hushlogin"
  else
    run_as_root touch "$TARGET_HOME/.hushlogin"
    run_as_root chown "$TARGET_USER":"$TARGET_GROUP" "$TARGET_HOME/.hushlogin"
  fi
}

main() {
  log_step "Checking operating system"
  require_supported_os
  log_step "Resolving target user"
  init_target_user
  log_step "Checking sudo privileges"
  require_sudo

  log_step "Installing common tools"
  install_common_tools
  log_step "Setting default editor"
  set_default_editor
  log_step "Configuring Docker"
  configure_docker
  log_step "Installing Docker"
  install_docker
  log_step "Configuring Vim"
  configure_vim
  log_step "Configuring passwordless sudo"
  configure_passwordless_sudo
  log_step "Configuring journald"
  configure_journald
  log_step "Configuring logrotate"
  configure_logrotate
  log_step "Disabling apt daily timers"
  disable_apt_daily_timers
  log_step "Disabling welcome message"
  disable_welcome_message
  log_step "Done."
}

main "$@"
