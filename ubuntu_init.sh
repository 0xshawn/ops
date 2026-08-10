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

readonly MIN_UBUNTU_MAJOR=22
readonly MIN_UBUNTU_MINOR=4
readonly DOCKER_DATA_ROOT="/data/docker"
readonly OS_RELEASE_PATH="${OS_RELEASE_FILE:-/etc/os-release}"
readonly SUDO_BIN="${SUDO_BIN:-sudo}"
readonly TASK_PROCESS_GONE=1
readonly TASK_PROCESS_UNINSPECTABLE=2
readonly TASK_SKIPPED=20
readonly TASK_TERMINATION_GRACE_MILLISECONDS=1000
readonly TASK_TERMINATION_TIMEOUT_MILLISECONDS=3000
readonly TASK_TERMINATION_POLL_SECONDS=0.05

TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""
INTERACTIVE_SELECTED_MODULES=""
INTERACTIVE_MENU_TTY_OPEN=0
TASK_LOG_FILE=""
TASK_COMMAND_PID=""
TASK_SPINNER_PID=""
TASK_STATE_FILE=""
TASK_CLEANUP_ACTIVE=0
TASK_PENDING_SIGNAL_STATUS=""
TASK_PROCESS_START=""
TASK_PROCESS_STATE=""
TASK_PROCESS_CHILDREN=()
TASK_NOW_MILLISECONDS=0
TASK_PROCESS_SCAN_EXPIRED=0
TASK_PROCESS_VERIFICATION_FAILED=0
TASK_ALL_TRACKED_PROCESSES_STOPPED=0
TASK_TRACKED_PROCESS_IDENTITIES=()
declare -A TASK_TRACKED_PROCESS_SEEN=()

die() {
  echo "$1" >&2
  return 1
}

log_step() {
  printf '\n==> %s\n' "$1"
}

task_process_details() {
  local details=()
  local pid="$1"
  local presence
  local stat
  local stat_fd
  local stat_path="/proc/$pid/stat"

  TASK_PROCESS_START=""
  TASK_PROCESS_STATE=""
  stat=""
  if { exec {stat_fd}<"$stat_path"; } 2>/dev/null; then
    IFS= read -r -d '' stat <&"$stat_fd" || true
    exec {stat_fd}<&-
  elif is_root; then
    [ ! -e "$stat_path" ] && return "$TASK_PROCESS_GONE"
    return "$TASK_PROCESS_UNINSPECTABLE"
  elif command -v "$SUDO_BIN" >/dev/null 2>&1; then
    if ! stat="$("$SUDO_BIN" -n /bin/cat "$stat_path" 2>/dev/null)"; then
      if ! presence="$("$SUDO_BIN" -n /bin/sh -c '
        if [ -e "$1" ]; then
          printf present
        else
          printf gone
        fi
      ' sh "$stat_path" 2>/dev/null)"; then
        return "$TASK_PROCESS_UNINSPECTABLE"
      fi
      [ "$presence" = gone ] && return "$TASK_PROCESS_GONE"
      return "$TASK_PROCESS_UNINSPECTABLE"
    fi
  else
    return "$TASK_PROCESS_UNINSPECTABLE"
  fi

  [ "${stat##*) }" != "$stat" ] || return "$TASK_PROCESS_UNINSPECTABLE"
  read -r -a details <<<"${stat##*) }"
  [ "${#details[@]}" -ge 20 ] || return "$TASK_PROCESS_UNINSPECTABLE"
  [[ "${details[19]}" =~ ^[0-9]+$ ]] || return "$TASK_PROCESS_UNINSPECTABLE"
  [[ "${details[0]}" =~ ^[A-Za-z]$ ]] || return "$TASK_PROCESS_UNINSPECTABLE"
  TASK_PROCESS_START="${details[19]}"
  TASK_PROCESS_STATE="${details[0]}"
}

task_process_children() {
  local child
  local child_file
  local -a child_files=()
  local children=""
  local deadline="$3"
  local expected_start="$2"
  local found=0
  local pid="$1"
  local status
  local -A seen=()

  TASK_PROCESS_CHILDREN=()
  if task_process_details "$pid"; then
    :
  else
    return "$?"
  fi
  [ "$TASK_PROCESS_START" = "$expected_start" ] || return "$TASK_PROCESS_GONE"
  case "$TASK_PROCESS_STATE" in
    Z|X) return "$TASK_PROCESS_GONE" ;;
  esac

  child_files=( "/proc/$pid"/task/*/children )
  for child_file in "${child_files[@]}"; do
    if task_deadline_reached "$deadline"; then
      TASK_PROCESS_SCAN_EXPIRED=1
      break
    fi
    [ -e "$child_file" ] || continue
    found=1
    children=""
    if children="$(/bin/cat "$child_file" 2>/dev/null)"; then
      :
    elif ! is_root && command -v "$SUDO_BIN" >/dev/null 2>&1; then
      children="$("$SUDO_BIN" -n /bin/cat "$child_file" 2>/dev/null)" ||
        return "$TASK_PROCESS_UNINSPECTABLE"
    elif [ -e "$child_file" ]; then
      return "$TASK_PROCESS_UNINSPECTABLE"
    else
      continue
    fi
    for child in $children; do
      [[ "$child" =~ ^[0-9]+$ ]] || return "$TASK_PROCESS_UNINSPECTABLE"
      if [ -z "${seen[$child]:-}" ]; then
        seen[$child]=1
        TASK_PROCESS_CHILDREN+=( "$child" )
      fi
    done
  done

  [ "$TASK_PROCESS_SCAN_EXPIRED" -eq 0 ] || return 0
  if [ "$found" -eq 0 ] && ! is_root && command -v "$SUDO_BIN" >/dev/null 2>&1; then
    if ! children="$("$SUDO_BIN" -n /bin/sh -c '
      found=0
      for child_file in "/proc/$1"/task/*/children; do
        [ -e "$child_file" ] || continue
        found=1
        /bin/cat "$child_file" || exit 1
        printf " "
      done
      [ "$found" -eq 1 ]
    ' sh "$pid" 2>/dev/null)"; then
      if task_process_details "$pid"; then
        [ "$TASK_PROCESS_START" = "$expected_start" ] || return "$TASK_PROCESS_GONE"
        return "$TASK_PROCESS_UNINSPECTABLE"
      else
        status=$?
      fi
      [ "$status" -eq "$TASK_PROCESS_GONE" ] && return "$TASK_PROCESS_GONE"
      return "$TASK_PROCESS_UNINSPECTABLE"
    fi
    for child in $children; do
      [[ "$child" =~ ^[0-9]+$ ]] || return "$TASK_PROCESS_UNINSPECTABLE"
      if [ -z "${seen[$child]:-}" ]; then
        seen[$child]=1
        TASK_PROCESS_CHILDREN+=( "$child" )
      fi
    done
  elif [ "$found" -eq 0 ]; then
    if task_process_details "$pid"; then
      [ "$TASK_PROCESS_START" = "$expected_start" ] || return "$TASK_PROCESS_GONE"
      return "$TASK_PROCESS_UNINSPECTABLE"
    else
      status=$?
    fi
    [ "$status" -eq "$TASK_PROCESS_GONE" ] && return "$TASK_PROCESS_GONE"
    return "$TASK_PROCESS_UNINSPECTABLE"
  fi
}

signal_task_process() {
  local expected_start="$3"
  local pid="$2"
  local status
  local task_signal="$1"

  if task_process_details "$pid"; then
    [ "$TASK_PROCESS_START" = "$expected_start" ] || return 0
    case "$TASK_PROCESS_STATE" in
      Z|X) return 0 ;;
    esac
  else
    status=$?
    [ "$status" -eq "$TASK_PROCESS_GONE" ] && return 0
    return "$TASK_PROCESS_UNINSPECTABLE"
  fi
  if kill "-$task_signal" "$pid" 2>/dev/null; then
    return 0
  fi

  if task_process_details "$pid"; then
    [ "$TASK_PROCESS_START" = "$expected_start" ] || return 0
    case "$TASK_PROCESS_STATE" in
      Z|X) return 0 ;;
    esac
  else
    status=$?
    [ "$status" -eq "$TASK_PROCESS_GONE" ] && return 0
    return "$TASK_PROCESS_UNINSPECTABLE"
  fi
  if ! is_root && command -v "$SUDO_BIN" >/dev/null 2>&1; then
    "$SUDO_BIN" -n /bin/kill "-$task_signal" "$pid" 2>/dev/null && return 0
  fi

  if task_process_details "$pid"; then
    [ "$TASK_PROCESS_START" = "$expected_start" ] || return 0
    case "$TASK_PROCESS_STATE" in
      Z|X) return 0 ;;
    esac
  else
    status=$?
    [ "$status" -eq "$TASK_PROCESS_GONE" ] && return 0
    return "$TASK_PROCESS_UNINSPECTABLE"
  fi
  return 1
}

task_time_milliseconds() {
  local fraction
  local seconds
  local uptime

  IFS= read -r uptime </proc/uptime || return 1
  uptime="${uptime%% *}"
  seconds="${uptime%%.*}"
  fraction="${uptime#*.}000"
  fraction="${fraction:0:3}"
  [[ "$seconds" =~ ^[0-9]+$ && "$fraction" =~ ^[0-9]+$ ]] || return 1
  TASK_NOW_MILLISECONDS=$((10#$seconds * 1000 + 10#$fraction))
}

task_deadline_reached() {
  local deadline="$1"

  if ! task_time_milliseconds; then
    TASK_PROCESS_VERIFICATION_FAILED=1
    return 0
  fi
  [ "$TASK_NOW_MILLISECONDS" -ge "$deadline" ]
}

track_task_process() {
  local identity="$1:$2"

  if [ -z "${TASK_TRACKED_PROCESS_SEEN[$identity]:-}" ]; then
    TASK_TRACKED_PROCESS_SEEN[$identity]=1
    TASK_TRACKED_PROCESS_IDENTITIES+=( "$identity" )
  fi
}

collect_task_process_tree() {
  local -a children=()
  local child
  local deadline="$3"
  local expected_start="$2"
  local pid="$1"
  local start
  local state
  local status

  if task_deadline_reached "$deadline"; then
    TASK_PROCESS_SCAN_EXPIRED=1
    return 1
  fi
  if task_process_details "$pid"; then
    start="$TASK_PROCESS_START"
    state="$TASK_PROCESS_STATE"
  else
    status=$?
    if [ "$status" -eq "$TASK_PROCESS_UNINSPECTABLE" ]; then
      TASK_PROCESS_VERIFICATION_FAILED=1
    fi
    return "$status"
  fi
  [ -z "$expected_start" ] || [ "$start" = "$expected_start" ] || return 0
  case "$state" in
    Z|X) return 0 ;;
  esac

  if task_process_children "$pid" "$start" "$deadline"; then
    children=( "${TASK_PROCESS_CHILDREN[@]}" )
  else
    status=$?
    children=( "${TASK_PROCESS_CHILDREN[@]}" )
    if [ "$status" -eq "$TASK_PROCESS_UNINSPECTABLE" ]; then
      TASK_PROCESS_VERIFICATION_FAILED=1
    fi
  fi

  for child in "${children[@]}"; do
    collect_task_process_tree "$child" "" "$deadline" || true
  done
  track_task_process "$pid" "$start"
}

signal_tracked_task_processes() {
  local deadline="$2"
  local expected_start
  local identity
  local pid
  local status
  local task_signal="$1"

  for identity in "${TASK_TRACKED_PROCESS_IDENTITIES[@]}"; do
    if task_deadline_reached "$deadline"; then
      TASK_PROCESS_SCAN_EXPIRED=1
      break
    fi
    pid="${identity%%:*}"
    expected_start="${identity#*:}"
    if signal_task_process "$task_signal" "$pid" "$expected_start"; then
      :
    else
      status=$?
      if [ "$status" -eq "$TASK_PROCESS_UNINSPECTABLE" ]; then
        TASK_PROCESS_VERIFICATION_FAILED=1
      fi
    fi
  done
}

verify_tracked_task_processes() {
  local deadline="$1"
  local expected_start
  local identity
  local pid
  local status

  TASK_ALL_TRACKED_PROCESSES_STOPPED=1
  for identity in "${TASK_TRACKED_PROCESS_IDENTITIES[@]}"; do
    if task_deadline_reached "$deadline"; then
      TASK_PROCESS_SCAN_EXPIRED=1
      TASK_ALL_TRACKED_PROCESSES_STOPPED=0
      break
    fi
    pid="${identity%%:*}"
    expected_start="${identity#*:}"
    if task_process_details "$pid"; then
      if [ "$TASK_PROCESS_START" = "$expected_start" ]; then
        case "$TASK_PROCESS_STATE" in
          Z|X) ;;
          *) TASK_ALL_TRACKED_PROCESSES_STOPPED=0 ;;
        esac
      fi
    else
      status=$?
      if [ "$status" -eq "$TASK_PROCESS_UNINSPECTABLE" ]; then
        TASK_PROCESS_VERIFICATION_FAILED=1
        TASK_ALL_TRACKED_PROCESSES_STOPPED=0
      fi
    fi
  done
}

run_task_termination_phase() {
  local deadline="$2"
  local expected_start="$4"
  local pid="$3"
  local task_signal="$1"

  while ! task_deadline_reached "$deadline"; do
    TASK_PROCESS_SCAN_EXPIRED=0
    collect_task_process_tree "$pid" "$expected_start" "$deadline" || true
    signal_tracked_task_processes "$task_signal" "$deadline"
    verify_tracked_task_processes "$deadline"
    if [ "$TASK_PROCESS_VERIFICATION_FAILED" -eq 0 ] &&
       [ "$TASK_PROCESS_SCAN_EXPIRED" -eq 0 ] &&
       [ "$TASK_ALL_TRACKED_PROCESSES_STOPPED" -eq 1 ]; then
      return 0
    fi
    task_deadline_reached "$deadline" && break
    sleep "$TASK_TERMINATION_POLL_SECONDS"
  done
  return 1
}

terminate_task_process_tree() {
  local expected_start="${2:-}"
  local final_deadline
  local pid="$1"
  local start
  local status
  local term_deadline

  TASK_PROCESS_SCAN_EXPIRED=0
  TASK_PROCESS_VERIFICATION_FAILED=0
  TASK_ALL_TRACKED_PROCESSES_STOPPED=0
  TASK_TRACKED_PROCESS_IDENTITIES=()
  TASK_TRACKED_PROCESS_SEEN=()

  if task_process_details "$pid"; then
    start="$TASK_PROCESS_START"
  else
    status=$?
    [ "$status" -eq "$TASK_PROCESS_GONE" ] && return 0
    printf 'Warning: unable to verify stopped task process %s.\n' "$pid" >&2
    return 1
  fi
  [ -z "$expected_start" ] || [ "$start" = "$expected_start" ] || return 0
  if ! task_time_milliseconds; then
    printf 'Warning: unable to verify stopped task process %s.\n' "$pid" >&2
    return 1
  fi
  term_deadline=$((TASK_NOW_MILLISECONDS + TASK_TERMINATION_GRACE_MILLISECONDS))
  final_deadline=$((TASK_NOW_MILLISECONDS + TASK_TERMINATION_TIMEOUT_MILLISECONDS))

  run_task_termination_phase TERM "$term_deadline" "$pid" "$start" && return 0
  run_task_termination_phase KILL "$final_deadline" "$pid" "$start" && return 0

  printf 'Warning: unable to verify stopped task process %s.\n' "$pid" >&2
  return 1
}

cleanup_task_status() {
  local pending_status

  [ "$TASK_CLEANUP_ACTIVE" -eq 0 ] || return 0
  TASK_CLEANUP_ACTIVE=1
  if [ -n "$TASK_COMMAND_PID" ]; then
    if terminate_task_process_tree "$TASK_COMMAND_PID"; then
      wait "$TASK_COMMAND_PID" 2>/dev/null || true
    fi
  fi

  if [ -n "$TASK_SPINNER_PID" ]; then
    if kill -0 "$TASK_SPINNER_PID" 2>/dev/null; then
      kill "$TASK_SPINNER_PID" 2>/dev/null || true
    fi
    wait "$TASK_SPINNER_PID" 2>/dev/null || true
  fi

  if [ -n "$TASK_LOG_FILE" ] && [ -t 1 ]; then
    printf '\033[?25h'
  fi

  if [ -n "$TASK_LOG_FILE" ]; then
    rm -f "$TASK_LOG_FILE"
  fi
  if [ -n "$TASK_STATE_FILE" ]; then
    rm -f "$TASK_STATE_FILE"
  fi

  TASK_COMMAND_PID=""
  TASK_LOG_FILE=""
  TASK_SPINNER_PID=""
  TASK_STATE_FILE=""
  TASK_CLEANUP_ACTIVE=0

  if [ -n "$TASK_PENDING_SIGNAL_STATUS" ]; then
    pending_status="$TASK_PENDING_SIGNAL_STATUS"
    TASK_PENDING_SIGNAL_STATUS=""
    exit "$pending_status"
  fi
}

handle_task_signal() {
  local status="$1"

  trap '' INT TERM HUP
  trap - EXIT
  if [ "$TASK_CLEANUP_ACTIVE" -eq 1 ]; then
    TASK_PENDING_SIGNAL_STATUS="$status"
    return
  fi
  cleanup_task_status
  exit "$status"
}

render_spinner() {
  local description="$1"
  local frame
  local frames=( '|' '/' '-' '\\' )
  local index=0

  while true; do
    frame="${frames[$index]}"
    printf '\r%s %s' "$frame" "$description"
    index=$(((index + 1) % ${#frames[@]}))
    sleep 0.1
  done
}

run_task() {
  local description="$1"
  local status
  local task_state=()
  shift
  TASK_LOG_FILE="$(mktemp)" || return
  TASK_STATE_FILE="$(mktemp)" || {
    status=$?
    rm -f "$TASK_LOG_FILE"
    TASK_LOG_FILE=""
    return "$status"
  }

  if [ -t 1 ]; then
    printf '\033[?25l'
    render_spinner "$description" &
    TASK_SPINNER_PID=$!
  else
    printf 'START %s\n' "$description"
  fi

  (
    if "$@"; then
      printf '%s\n' "$TARGET_USER" "$TARGET_HOME" "$TARGET_GROUP" >"$TASK_STATE_FILE"
      exit 0
    else
      exit "$?"
    fi
  ) >"$TASK_LOG_FILE" 2>&1 &
  TASK_COMMAND_PID=$!

  if wait "$TASK_COMMAND_PID"; then
    status=0
  else
    status=$?
  fi
  TASK_COMMAND_PID=""

  if [ "$status" -eq 0 ]; then
    mapfile -t task_state <"$TASK_STATE_FILE"
    TARGET_USER="${task_state[0]:-}"
    TARGET_HOME="${task_state[1]:-}"
    TARGET_GROUP="${task_state[2]:-}"
  fi

  if [ -n "$TASK_SPINNER_PID" ]; then
    kill "$TASK_SPINNER_PID" 2>/dev/null || true
    wait "$TASK_SPINNER_PID" 2>/dev/null || true
    TASK_SPINNER_PID=""
  fi

  if [ "$status" -eq 0 ]; then
    [ -t 1 ] && printf '\r\033[2K✓ %s\n' "$description" || printf 'OK %s\n' "$description"
    cleanup_task_status
    return 0
  fi

  if [ "$status" -eq "$TASK_SKIPPED" ]; then
    [ -t 1 ] && printf '\r\033[2K- %s (skipped)\n' "$description" || printf 'SKIPPED %s\n' "$description"
    cleanup_task_status
    return 0
  fi

  [ -t 1 ] && printf '\r\033[2K✗ %s\n' "$description" || printf 'FAILED %s\n' "$description"
  cat "$TASK_LOG_FILE"
  cleanup_task_status
  return "$status"
}

unsupported_os() {
  die "Error: This script is only supported on Ubuntu >= 22.04."
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

require_sudo() {
  if is_root; then
    return 0
  fi

  command -v "$SUDO_BIN" >/dev/null 2>&1 || {
    die "This script requires sudo."
    return 1
  }

  if "$SUDO_BIN" -n true 2>/dev/null; then
    return 0
  fi

  if [ -r /dev/tty ]; then
    "$SUDO_BIN" -v </dev/tty || {
      die "This script requires sudo privileges."
      return 1
    }
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

  target_shell="$(getent passwd "$TARGET_USER" | cut -d: -f7)" || return
  [ -n "$target_shell" ] || target_shell="${SHELL:-/bin/sh}"

  if [ "$TARGET_USER" = "$(id -un)" ]; then
    HOME="$TARGET_HOME" SHELL="$target_shell" PATH="$TARGET_HOME/.local/bin:$PATH" "$@"
    return
  fi

  if is_root; then
    command -v runuser >/dev/null 2>&1 || {
      die "This script requires runuser to switch to $TARGET_USER."
      return 1
    }
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" SHELL="$target_shell" \
      PATH="$TARGET_HOME/.local/bin:$PATH" "$@"
    return
  fi

  "$SUDO_BIN" -H -u "$TARGET_USER" env HOME="$TARGET_HOME" SHELL="$target_shell" \
    PATH="$TARGET_HOME/.local/bin:$PATH" "$@"
}

write_root_file() {
  local path="$1"
  local mode="${2:-0644}"
  local status
  local tmp_file

  tmp_file="$(mktemp)" || return
  cat >"$tmp_file" || {
    status=$?
    rm -f "$tmp_file"
    return "$status"
  }
  run_as_root install -m "$mode" -D "$tmp_file" "$path" || {
    status=$?
    rm -f "$tmp_file"
    return "$status"
  }
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

  [ -r "$OS_RELEASE_PATH" ] || {
    unsupported_os
    return 1
  }

  os_id="$(read_os_release_value ID "$OS_RELEASE_PATH" || true)"
  version_id="$(read_os_release_value VERSION_ID "$OS_RELEASE_PATH" || true)"

  [ "$os_id" = "ubuntu" ] || {
    unsupported_os
    return 1
  }
  version_at_least_minimum "$version_id" || {
    unsupported_os
    return 1
  }
}

init_target_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
  else
    TARGET_USER="$(id -un)" || return
  fi

  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)" || return
  TARGET_GROUP="$(id -gn "$TARGET_USER")" || return

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

  run_as_root apt update || return
  run_as_root apt install -y "${packages[@]}"
}

initialize_zsh() {
  local zsh_path

  zsh_path="$(command -v zsh || true)"
  if [ -z "$zsh_path" ]; then
    log_step "zsh is not installed; skipping zsh initialization"
    return
  fi

  run_as_root chsh -s "$zsh_path" "$TARGET_USER" || return
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

target_user_has_command() {
  local command_name="$1"

  run_as_target_user bash -c '
    export PATH="$HOME/.local/bin:$PATH"
    export NVM_DIR="$HOME/.nvm"
    [ ! -s "$NVM_DIR/nvm.sh" ] || . "$NVM_DIR/nvm.sh"
    command -v "$1" >/dev/null 2>&1
  ' bash "$command_name"
}

install_codex() {
  if target_user_has_command codex; then
    return "$TASK_SKIPPED"
  fi

  if ! target_user_has_command node; then
    install_node || return
  fi

  run_as_target_user bash -c '
    set -euo pipefail
    curl -fsSL https://chatgpt.com/codex/install.sh | sh
  ' || return

  if ! target_user_has_command codex; then
    die "Codex installation completed without installing the codex command."
    return 1
  fi
}

install_code_review_graph() {
  if target_user_has_command code-review-graph; then
    return "$TASK_SKIPPED"
  fi

  if ! target_user_has_command pipx; then
    run_as_root apt update || return
    run_as_root apt install -y pipx || return
  fi

  run_as_target_user pipx install code-review-graph || return

  if ! target_user_has_command code-review-graph; then
    die "code-review-graph installation completed without installing the code-review-graph command."
    return 1
  fi
}

set_default_editor() {
  run_as_root update-alternatives --set editor /usr/bin/vim.basic
}

configure_docker() {
  run_as_root mkdir -p "$DOCKER_DATA_ROOT" || return
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
    run_as_root mkdir -p /etc/apt/sources.list.d || return
    wget -qO- get.docker.com | run_as_root bash || return
  fi

  command -v docker >/dev/null 2>&1 || {
    die "Docker installation completed without installing the docker command."
    return 1
  }

  run_as_root systemctl enable docker || return
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
  write_root_file "/etc/systemd/journald.conf.d/00-journal-limit.conf" <<EOL || return
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=200M
MaxRetentionSec=14day
EOL
  run_as_root systemctl restart systemd-journal-flush.service || return
  run_as_root systemctl restart systemd-journald
}

configure_logrotate() {
  if run_as_root test -f /etc/logrotate.conf; then
    if ! run_as_root grep -q "maxsize" /etc/logrotate.conf; then
      run_as_root sed -i '/^# global options/a \    maxsize 1G' /etc/logrotate.conf || return
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
    run_as_root touch "$TARGET_HOME/.hushlogin" || return
    run_as_root chown "$TARGET_USER":"$TARGET_GROUP" "$TARGET_HOME/.hushlogin"
  fi
}

# Modules in execution order. Selecting a subset always runs in this order,
# regardless of the order given on the command line.
readonly MODULE_ORDER=(
  install_common_tools
  initialize_zsh
  install_node
  install_codex
  install_code_review_graph
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

readonly CATEGORY_ORDER=(base_tools development_tools docker system_configuration)

category_description() {
  case "$1" in
    base_tools) printf '%s' "Base tools" ;;
    development_tools) printf '%s' "Development tools" ;;
    docker) printf '%s' "Docker" ;;
    system_configuration) printf '%s' "System configuration" ;;
    *) die "Missing description for category: $1" ;;
  esac
}

category_modules() {
  case "$1" in
    base_tools)
      printf '%s' "install_common_tools initialize_zsh set_default_editor configure_vim"
      ;;
    development_tools)
      printf '%s' "install_node install_codex install_code_review_graph"
      ;;
    docker) printf '%s' "configure_docker install_docker" ;;
    system_configuration)
      printf '%s' "configure_passwordless_sudo configure_journald configure_logrotate disable_apt_daily_timers disable_welcome_message"
      ;;
    *) die "Missing modules for category: $1" ;;
  esac
}

module_description() {
  case "$1" in
    install_common_tools) printf '%s' "Installing common tools" ;;
    initialize_zsh) printf '%s' "Initializing zsh" ;;
    install_node) printf '%s' "Installing Node.js" ;;
    install_codex) printf '%s' "Installing Codex" ;;
    install_code_review_graph) printf '%s' "Installing code-review-graph" ;;
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
  local category
  local category_child_count
  local category_index
  local category_selected_count
  local escape_sequence
  local expanded=(0 0 0 0)
  local focused_type
  local focused_value
  local index
  local key
  local last_visible_index
  local marker
  local menu_line_count=0
  local message=""
  local module
  local module_index
  local rendered=0
  local selected_count
  local selected=()
  local visible_types=()
  local visible_values=()

  exec 3<>/dev/tty 2>/dev/null || return 1
  INTERACTIVE_MENU_TTY_OPEN=1
  trap 'cleanup_interactive_menu; cleanup_task_status' EXIT
  trap 'cleanup_interactive_menu; cleanup_task_status; exit 130' INT TERM HUP

  for ((index = 0; index < ${#MODULE_ORDER[@]}; index++)); do
    selected[index]=1
  done

  printf '\033[?25l' >&3

  while true; do
    if [ "$rendered" -eq 1 ]; then
      printf '\033[%dA' "$menu_line_count" >&3
    fi

    visible_types=()
    visible_values=()
    for ((category_index = 0; category_index < ${#CATEGORY_ORDER[@]}; category_index++)); do
      category="${CATEGORY_ORDER[$category_index]}"
      visible_types+=(category)
      visible_values+=("$category")
      if [ "${expanded[$category_index]}" -eq 1 ]; then
        for module in $(category_modules "$category"); do
          visible_types+=(module)
          visible_values+=("$module")
        done
      fi
    done

    printf '\033[2K\rSelect modules to install\n' >&3
    printf '\033[2K\rUse Up/Down to move, Right/Left to expand/collapse, Space to toggle, Enter to confirm.\n' >&3

    if [ "$current" -eq -1 ]; then
      printf '\033[2K\r\033[7m> [ Clear all selections ]\033[0m\n' >&3
    else
      printf '\033[2K\r  [ Clear all selections ]\n' >&3
    fi
    printf '\033[2K\r----------------------------------------\n' >&3

    for ((index = 0; index < ${#visible_values[@]}; index++)); do
      focused_type="${visible_types[$index]}"
      focused_value="${visible_values[$index]}"

      if [ "$focused_type" = category ]; then
        category_selected_count=0
        category_child_count=0
        for module in $(category_modules "$focused_value"); do
          category_child_count=$((category_child_count + 1))
          for ((module_index = 0; module_index < ${#MODULE_ORDER[@]}; module_index++)); do
            if [ "${MODULE_ORDER[$module_index]}" = "$module" ] && [ "${selected[$module_index]}" -eq 1 ]; then
              category_selected_count=$((category_selected_count + 1))
            fi
          done
        done

        marker=" "
        if [ "$category_selected_count" -eq "$category_child_count" ]; then
          marker="x"
        elif [ "$category_selected_count" -gt 0 ]; then
          marker="-"
        fi

        if [ "$index" -eq "$current" ]; then
          printf '\033[2K\r\033[7m> [%s] %s\033[0m\n' \
            "$marker" "$(category_description "$focused_value")" >&3
        else
          printf '\033[2K\r  [%s] %s\n' \
            "$marker" "$(category_description "$focused_value")" >&3
        fi
        continue
      fi

      for ((module_index = 0; module_index < ${#MODULE_ORDER[@]}; module_index++)); do
        [ "${MODULE_ORDER[$module_index]}" = "$focused_value" ] && break
      done
      marker=" "
      [ "${selected[$module_index]}" -eq 1 ] && marker="x"

      if [ "$index" -eq "$current" ]; then
        printf '\033[2K\r\033[7m>   [%s] %-28s %s\033[0m\n' \
          "$marker" "$focused_value" "$(module_description "$focused_value")" >&3
      else
        printf '\033[2K\r    [%s] %-28s %s\n' \
          "$marker" "$focused_value" "$(module_description "$focused_value")" >&3
      fi
    done

    printf '\033[2K\r%s\n' "$message" >&3
    rendered=1
    menu_line_count=$((${#visible_values[@]} + 5))
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
            last_visible_index=$((${#visible_values[@]} - 1))
            if [ "$current" -eq -1 ]; then
              current=$last_visible_index
            elif [ "$current" -eq 0 ]; then
              current=-1
            else
              current=$((current - 1))
            fi
            ;;
          '[B')
            last_visible_index=$((${#visible_values[@]} - 1))
            if [ "$current" -eq -1 ]; then
              current=0
            elif [ "$current" -eq "$last_visible_index" ]; then
              current=-1
            else
              current=$((current + 1))
            fi
            ;;
          '[C'|'[D')
            if [ "$current" -ge 0 ] && [ "${visible_types[$current]}" = category ]; then
              focused_value="${visible_values[$current]}"
              for ((category_index = 0; category_index < ${#CATEGORY_ORDER[@]}; category_index++)); do
                if [ "${CATEGORY_ORDER[$category_index]}" = "$focused_value" ]; then
                  if [ "$escape_sequence" = '[C' ]; then
                    expanded[$category_index]=1
                  else
                    expanded[$category_index]=0
                  fi
                  break
                fi
              done
            fi
            ;;
        esac
        ;;
      ' ')
        if [ "$current" -eq -1 ]; then
          for ((index = 0; index < ${#MODULE_ORDER[@]}; index++)); do
            selected[index]=0
          done
          current=0
          continue
        fi

        focused_type="${visible_types[$current]}"
        focused_value="${visible_values[$current]}"
        if [ "$focused_type" = category ]; then
          category_child_count=0
          category_selected_count=0
          for module in $(category_modules "$focused_value"); do
            category_child_count=$((category_child_count + 1))
            for ((module_index = 0; module_index < ${#MODULE_ORDER[@]}; module_index++)); do
              if [ "${MODULE_ORDER[$module_index]}" = "$module" ]; then
                category_selected_count=$((category_selected_count + selected[$module_index]))
                break
              fi
            done
          done
          for module in $(category_modules "$focused_value"); do
            for ((module_index = 0; module_index < ${#MODULE_ORDER[@]}; module_index++)); do
              if [ "${MODULE_ORDER[$module_index]}" = "$module" ]; then
                if [ "$category_selected_count" -eq "$category_child_count" ]; then
                  selected[$module_index]=0
                else
                  selected[$module_index]=1
                fi
                break
              fi
            done
          done
        else
          for ((module_index = 0; module_index < ${#MODULE_ORDER[@]}; module_index++)); do
            if [ "${MODULE_ORDER[$module_index]}" = "$focused_value" ]; then
              if [ "${selected[$module_index]}" -eq 1 ]; then
                selected[$module_index]=0
              else
                selected[$module_index]=1
              fi
              break
            fi
          done
        fi
        continue

        ;;
      ''|$'\r')

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
  run_task "$(module_description "$module")" "$module"
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
        return 1
        ;;
      *)
        is_known_module "$1" || {
          die "Unknown module: $1 (use --list to see available modules)"
          return 1
        }
        selected_modules="$selected_modules $1"
        run_all=0
        ;;
    esac
    shift
  done

  if [ "$original_arg_count" -eq 0 ] && has_controlling_terminal; then
    select_modules_interactively || {
      die "Unable to read the interactive selection."
      return 1
    }
    selected_modules="$INTERACTIVE_SELECTED_MODULES"
    run_all=0
  fi

  trap 'cleanup_task_status' EXIT
  trap 'handle_task_signal 130' INT
  trap 'handle_task_signal 143' TERM
  trap 'handle_task_signal 129' HUP

  run_task "Checking operating system" require_supported_os
  run_task "Resolving target user" init_target_user
  run_task "Checking sudo privileges" require_sudo

  local module
  for module in "${MODULE_ORDER[@]}"; do
    if [ "$run_all" -eq 1 ] || is_selected_module "$module" "$selected_modules"; then
      run_module "$module"
    fi
  done

  cleanup_task_status
  trap - EXIT INT TERM HUP
  log_step "Done."
}

main "$@"
