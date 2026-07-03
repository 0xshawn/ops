#!/usr/bin/env bash

set -euo pipefail

# Usage:
#   sudo ./ubuntu_init.sh
#   wget -qO- <url-to-this-script> | sudo bash

unsupported_os() {
  echo "Error: This script is only supported on Ubuntu >= 24.04." >&2
  exit 1
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

ensure_supported_os() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local os_id
  local version_id
  local version_major
  local version_minor

  [ -r "$os_release_file" ] || unsupported_os

  os_id="$(read_os_release_value ID "$os_release_file" || true)"
  version_id="$(read_os_release_value VERSION_ID "$os_release_file" || true)"

  [ "$os_id" = "ubuntu" ] || unsupported_os

  version_major="${version_id%%.*}"
  version_minor="${version_id#*.}"
  if [ "$version_minor" = "$version_id" ]; then
    version_minor="0"
  else
    version_minor="${version_minor%%.*}"
  fi

  case "$version_major" in
    ''|*[!0-9]*) unsupported_os ;;
  esac
  case "$version_minor" in
    ''|*[!0-9]*) unsupported_os ;;
  esac

  version_major=$((10#$version_major))
  version_minor=$((10#$version_minor))

  if [ "$version_major" -lt 24 ] ||
    { [ "$version_major" -eq 24 ] && [ "$version_minor" -lt 4 ]; }; then
    unsupported_os
  fi
}

ensure_supported_os

# Must run as root.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root" >&2
  exit 1
fi

# Set vim as default editor
update-alternatives --set editor /usr/bin/vim.basic

# Install common tools
apt update && \
apt install -y git vim curl wget htop atop iotop tmux mtr \
    unzip zip zsh tree mosh \
    jq build-essential

# Change Docker root
mkdir -p /etc/docker /data/docker
cat >/etc/docker/daemon.json <<EOL
{
  "data-root": "/data/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file":"5"
  }
}
EOL

# Install Docker
wget -qO- get.docker.com | bash
systemctl enable docker

# vim
cat >/etc/vim/vimrc.local <<EOL
filetype plugin indent on
" show existing tab with 4 spaces width
set tabstop=4
" when indenting with '>', use 4 spaces width
set shiftwidth=4
" On pressing tab, insert 4 spaces
set expandtab
EOL

# sudo without password
cat >/etc/sudoers.d/sudo <<EOL
%sudo ALL=(ALL) NOPASSWD: ALL
EOL

# log rotate
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/00-journal-limit.conf <<EOL
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=200M
MaxRetentionSec=14day
EOL
systemctl restart systemd-journal-flush.service
systemctl restart systemd-journald
# Change global logrotate config for non-systemd log
if [ -f /etc/logrotate.conf ]; then
    if ! grep -q "maxsize" /etc/logrotate.conf; then
        sed -i '/^# global options/a \    maxsize 1G' /etc/logrotate.conf
    fi
    sed -i 's/#compress/compress/g' /etc/logrotate.conf
fi

# Disable apt daily timer
systemctl mask \
    apt-daily.service \
    apt-daily.timer \
    apt-daily-upgrade.service \
    apt-daily-upgrade.timer

# Disable welcome message
touch ~/.hushlogin
