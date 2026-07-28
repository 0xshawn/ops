#!/usr/bin/env bash

set -euo pipefail

# Usage:
#   sudo ./ubuntu_init.sh                       # choose modules interactively
#   ./ubuntu_init.sh                            # choose modules interactively
#   ./ubuntu_init.sh all                        # run every module
#   ./ubuntu_init.sh disable_welcome_message    # run only selected modules
#   ./ubuntu_init.sh --list                     # list available modules
#   curl -fsSL <url-to-this-script> | bash
#   curl -fsSL <url-to-this-script> | bash -s -- disable_welcome_message

readonly MIN_UBUNTU_MAJOR=24
readonly MIN_UBUNTU_MINOR=4
readonly DOCKER_DATA_ROOT="/data/docker"
readonly OS_RELEASE_PATH="${OS_RELEASE_FILE:-/etc/os-release}"
readonly SUDO_BIN="${SUDO_BIN:-sudo}"

TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""
INTERACTIVE_SELECTED_MODULES=""
INTERACTIVE_MENU_TTY_OPEN=0

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

run_as_target_user() {
  local target_shell

  target_shell="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
  [ -n "$target_shell" ] || target_shell="${SHELL:-/bin/sh}"

  if [ "$TARGET_USER" = "$(id -un)" ]; then
    HOME="$TARGET_HOME" SHELL="$target_shell" "$@"
    return
  fi

  if is_root; then
    command -v runuser >/dev/null 2>&1 ||
      die "This script requires runuser to switch to $TARGET_USER."
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" SHELL="$target_shell" "$@"
    return
  fi

  "$SUDO_BIN" -H -u "$TARGET_USER" env HOME="$TARGET_HOME" SHELL="$target_shell" "$@"
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

initialize_zsh() {
  local zsh_path

  zsh_path="$(command -v zsh || true)"
  if [ -z "$zsh_path" ]; then
    log_step "zsh is not installed; skipping zsh initialization"
    return
  fi

  run_as_root chsh -s "$zsh_path" "$TARGET_USER"
  run_as_target_user zsh -lc '
    set -euo pipefail

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
      sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc
    fi

    if [ ! -d "$HOME/.fzf" ]; then
      git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
    fi

    "$HOME/.fzf/install" --all
  '
}

install_node() {
  run_as_target_user bash -c '
    set -euo pipefail
    export NVM_DIR="$HOME/.nvm"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh | bash
    [ -s "$NVM_DIR/nvm.sh" ] || exit 1
    . "$NVM_DIR/nvm.sh"
    nvm install --lts
  '
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

# Modules in execution order. Selecting a subset always runs in this order,
# regardless of the order given on the command line.
readonly MODULE_ORDER=(
  install_common_tools
  initialize_zsh
  install_node
  set_default_editor
  configure_docker
  install_docker
  configure_vim
  configure_passwordless_sudo
  configure_journald
  configure_logrotate
  disable_apt_daily_timers
  disable_welcome_message
)

module_description() {
  case "$1" in
    install_common_tools) printf '%s' "Installing common tools" ;;
    initialize_zsh) printf '%s' "Initializing zsh" ;;
    install_node) printf '%s' "Installing Node.js" ;;
    set_default_editor) printf '%s' "Setting default editor" ;;
    configure_docker) printf '%s' "Configuring Docker" ;;
    install_docker) printf '%s' "Installing Docker" ;;
    configure_vim) printf '%s' "Configuring Vim" ;;
    configure_passwordless_sudo) printf '%s' "Configuring passwordless sudo" ;;
    configure_journald) printf '%s' "Configuring journald" ;;
    configure_logrotate) printf '%s' "Configuring logrotate" ;;
    disable_apt_daily_timers) printf '%s' "Disabling apt daily timers" ;;
    disable_welcome_message) printf '%s' "Disabling welcome message" ;;
    *) die "Missing description for module: $1" ;;
  esac
}

is_known_module() {
  local candidate="$1"
  local module
  for module in "${MODULE_ORDER[@]}"; do
    [ "$module" = "$candidate" ] && return 0
  done
  return 1
}

list_modules() {
  local module
  for module in "${MODULE_ORDER[@]}"; do
    printf '  %-28s %s\n' "$module" "$(module_description "$module")"
  done
}

has_controlling_terminal() {
  (exec 3<>/dev/tty) 2>/dev/null
}

cleanup_interactive_menu() {
  if [ "$INTERACTIVE_MENU_TTY_OPEN" -eq 1 ]; then
    printf '\033[?25h' >&3 2>/dev/null || true
    exec 3>&-
    INTERACTIVE_MENU_TTY_OPEN=0
  fi
}

select_modules_interactively() {
  local current=0
  local escape_sequence
  local index
  local key
  local marker
  local menu_line_count
  local message=""
  local module
  local rendered=0
  local selected_count
  local selected=()

  exec 3<>/dev/tty 2>/dev/null || return 1
  INTERACTIVE_MENU_TTY_OPEN=1
  trap 'cleanup_interactive_menu' EXIT
  trap 'cleanup_interactive_menu; exit 130' INT TERM HUP

  for ((index = 0; index < ${#MODULE_ORDER[@]}; index++)); do
    selected[index]=1
  done

  menu_line_count=$((${#MODULE_ORDER[@]} + 5))
  printf '\033[?25l' >&3

  while true; do
    if [ "$rendered" -eq 1 ]; then
      printf '\033[%dA' "$menu_line_count" >&3
    fi

    printf '\033[2K\rSelect modules to install\n' >&3
    printf '\033[2K\rUse Up/Down to move, Space to toggle, Enter to confirm.\n' >&3

    if [ "$current" -eq -1 ]; then
      printf '\033[2K\r\033[7m> [ Clear all selections ]\033[0m\n' >&3
    else
      printf '\033[2K\r  [ Clear all selections ]\n' >&3
    fi
    printf '\033[2K\r----------------------------------------\n' >&3

    for ((index = 0; index < ${#MODULE_ORDER[@]}; index++)); do
      module="${MODULE_ORDER[$index]}"
      marker=" "
      [ "${selected[$index]}" -eq 1 ] && marker="x"

      if [ "$index" -eq "$current" ]; then
        printf '\033[2K\r\033[7m> [%s] %-28s %s\033[0m\n' \
          "$marker" "$module" "$(module_description "$module")" >&3
      else
        printf '\033[2K\r  [%s] %-28s %s\n' \
          "$marker" "$module" "$(module_description "$module")" >&3
      fi
    done

    printf '\033[2K\r%s\n' "$message" >&3
    rendered=1
    message=""
    key=""

    if ! IFS= read -rsn1 key <&3; then
      cleanup_interactive_menu
      trap - EXIT INT TERM HUP
      return 1
    fi

    case "$key" in
      $'\033')
        escape_sequence=""
        IFS= read -rsn2 -t 0.1 escape_sequence <&3 || true
        case "$escape_sequence" in
          '[A')
            if [ "$current" -eq -1 ]; then
              current=$((${#MODULE_ORDER[@]} - 1))
            elif [ "$current" -eq 0 ]; then
              current=-1
            else
              current=$((current - 1))
            fi
            ;;
          '[B')
            if [ "$current" -eq -1 ]; then
              current=0
            elif [ "$current" -eq $((${#MODULE_ORDER[@]} - 1)) ]; then
              current=-1
            else
              current=$((current + 1))
            fi
            ;;
        esac
        ;;
      ' '| '')
        if [ "$current" -eq -1 ]; then
          for ((index = 0; index < ${#MODULE_ORDER[@]}; index++)); do
            selected[index]=0
          done
          current=0
          continue
        fi

        if [ "$key" = ' ' ]; then
          if [ "${selected[$current]}" -eq 1 ]; then
            selected[current]=0
          else
            selected[current]=1
          fi
          continue
        fi

        selected_count=0
        INTERACTIVE_SELECTED_MODULES=""
        for ((index = 0; index < ${#MODULE_ORDER[@]}; index++)); do
          if [ "${selected[$index]}" -eq 1 ]; then
            module="${MODULE_ORDER[$index]}"
            if [ -z "$INTERACTIVE_SELECTED_MODULES" ]; then
              INTERACTIVE_SELECTED_MODULES="$module"
            else
              INTERACTIVE_SELECTED_MODULES="$INTERACTIVE_SELECTED_MODULES $module"
            fi
            selected_count=$((selected_count + 1))
          fi
        done

        if [ "$selected_count" -eq 0 ]; then
          message="Select at least one module."
          continue
        fi

        cleanup_interactive_menu
        trap - EXIT INT TERM HUP
        return 0
        ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: ubuntu_init.sh [options] [module ...]

With no arguments in an interactive terminal, choose modules from the menu.
Without a controlling terminal, an argument-free run executes every module.
Pass module names to run only those modules.
Selected modules always run in their canonical order.

Options:
  -l, --list   List available modules and exit
  -h, --help   Show this help and exit

Arguments:
  all          Run every module without opening the interactive menu

Modules:
$(list_modules)
EOF
}

run_module() {
  local module="$1"
  log_step "$(module_description "$module")"
  "$module"
}

is_selected_module() {
  local candidate="$1"
  local selected_modules="$2"

  case " $selected_modules " in
    *" $candidate "*) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  local original_arg_count="$#"
  local run_all=1
  local selected_modules=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -l|--list)
        list_modules
        exit 0
        ;;
      all)
        run_all=1
        ;;
      -*)
        die "Unknown option: $1 (use --help for usage)"
        ;;
      *)
        is_known_module "$1" ||
          die "Unknown module: $1 (use --list to see available modules)"
        selected_modules="$selected_modules $1"
        run_all=0
        ;;
    esac
    shift
  done

  if [ "$original_arg_count" -eq 0 ] && has_controlling_terminal; then
    select_modules_interactively || die "Unable to read the interactive selection."
    selected_modules="$INTERACTIVE_SELECTED_MODULES"
    run_all=0
  fi

  log_step "Checking operating system"
  require_supported_os
  log_step "Resolving target user"
  init_target_user
  log_step "Checking sudo privileges"
  require_sudo

  local module
  for module in "${MODULE_ORDER[@]}"; do
    if [ "$run_all" -eq 1 ] || is_selected_module "$module" "$selected_modules"; then
      run_module "$module"
    fi
  done

  log_step "Done."
}

main "$@"
