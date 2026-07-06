#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(
  "ubuntu_init.sh"
)
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

UBUNTU_22_04_OS_RELEASE="$TMP_DIR/ubuntu-22.04-os-release"
UBUNTU_24_04_OS_RELEASE="$TMP_DIR/ubuntu-24.04-os-release"
UBUNTU_24_10_OS_RELEASE="$TMP_DIR/ubuntu-24.10-os-release"
DEBIAN_12_OS_RELEASE="$TMP_DIR/debian-12-os-release"

cat >"$UBUNTU_22_04_OS_RELEASE" <<'EOL'
ID=ubuntu
VERSION_ID="22.04"
EOL

cat >"$UBUNTU_24_04_OS_RELEASE" <<'EOL'
ID=ubuntu
VERSION_ID="24.04"
EOL

cat >"$UBUNTU_24_10_OS_RELEASE" <<'EOL'
ID=ubuntu
VERSION_ID="24.10"
EOL

cat >"$DEBIAN_12_OS_RELEASE" <<'EOL'
ID=debian
VERSION_ID="12"
EOL

failures=0

check() {
  local description="$1"
  shift

  if "$@"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description" >&2
    failures=$((failures + 1))
  fi
}

has_single_top_level_script() {
  local scripts

  scripts="$(
    cd "$ROOT_DIR" &&
      find . -maxdepth 1 -type f -name '*.sh' -print |
      sed 's#^\./##' |
      sort
  )"

  [ "$scripts" = "ubuntu_init.sh" ]
}

unsupported_os_fails_before_root_check() {
  local os_release_file="$1"
  local output
  local status

  set +e
  output="$(OS_RELEASE_FILE="$os_release_file" bash "$ROOT_DIR/ubuntu_init.sh" 2>&1)"
  status=$?

  [ "$status" -eq 1 ] &&
    grep -q "Error: This script is only supported on Ubuntu >= 24.04." <<<"$output" &&
    ! grep -q "Please run as root" <<<"$output"
}

supports_normal_user_entrypoint() {
  grep -q '^require_sudo() {' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q '^run_as_root() {' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q '"$SUDO_BIN" -n true' "$ROOT_DIR/ubuntu_init.sh" &&
    ! grep -q '^require_root() {' "$ROOT_DIR/ubuntu_init.sh" &&
    ! grep -q 'Please run as root' "$ROOT_DIR/ubuntu_init.sh"
}

system_changes_use_sudo_helper() {
  grep -q 'run_as_root apt update' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'run_as_root apt install' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'run_as_root update-alternatives' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'run_as_root systemctl enable docker' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'run_as_root systemctl mask' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'write_root_file "/etc/docker/daemon.json"' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'write_root_file "/etc/sudoers.d/sudo" "0440"' "$ROOT_DIR/ubuntu_init.sh"
}

docker_install_is_idempotent() {
  awk '
    /^install_docker\(\) \{/ { in_func = 1 }
    in_func && /command -v docker/ { saw_docker_check = 1 }
    in_func && /Docker is already installed/ { saw_skip_message = 1 }
    in_func && /get\.docker\.com/ { saw_installer = 1 }
    in_func && /systemctl enable docker/ { saw_enable = 1 }
    in_func && /systemctl restart docker/ { saw_restart = 1 }
    in_func && /^}/ { in_func = 0 }
    END {
      exit !(saw_docker_check && saw_skip_message && saw_installer && saw_enable && saw_restart)
    }
  ' "$ROOT_DIR/ubuntu_init.sh"
}

user_config_targets_invoking_user() {
  grep -q '^init_target_user() {' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'TARGET_HOME' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'TARGET_USER' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q '"$TARGET_HOME/.hushlogin"' "$ROOT_DIR/ubuntu_init.sh"
}

readme_uses_normal_user_remote_command() {
  grep -q 'curl -fsSL https://raw.githubusercontent.com/0xshawn/ops/main/ubuntu_init.sh | bash' "$ROOT_DIR/README.md" &&
    ! grep -q 'sudo bash' "$ROOT_DIR/README.md" &&
    ! grep -q '0xshawn/life-is-short' "$ROOT_DIR/README.md"
}

has_main_entrypoint() {
  grep -q '^main "\$@"$' "$ROOT_DIR/ubuntu_init.sh"
}

main_installs_tools_before_setting_editor() {
  awk '
    /^readonly MODULE_ORDER=\(/ { in_list = 1 }
    in_list && /install_common_tools/ { install_line = NR }
    in_list && /set_default_editor/ { editor_line = NR }
    in_list && /^\)/ { in_list = 0 }
    END {
      exit !(install_line > 0 && editor_line > 0 && install_line < editor_line)
    }
  ' "$ROOT_DIR/ubuntu_init.sh"
}

main_installs_node_after_common_tools() {
  awk '
    /^readonly MODULE_ORDER=\(/ { in_list = 1 }
    in_list && /install_common_tools/ { tools_line = NR }
    in_list && /install_node/ { node_line = NR }
    in_list && /^\)/ { in_list = 0 }
    END {
      exit !(tools_line > 0 && node_line > 0 && tools_line < node_line)
    }
  ' "$ROOT_DIR/ubuntu_init.sh"
}

main_initializes_zsh_after_common_tools() {
  awk '
    /^readonly MODULE_ORDER=\(/ { in_list = 1 }
    in_list && /install_common_tools/ { tools_line = NR }
    in_list && /initialize_zsh/ { zsh_line = NR }
    in_list && /^\)/ { in_list = 0 }
    END {
      exit !(tools_line > 0 && zsh_line > 0 && tools_line < zsh_line)
    }
  ' "$ROOT_DIR/ubuntu_init.sh"
}

node_install_uses_nvm_lts() {
  awk '
    /^install_node\(\) \{/ { in_func = 1 }
    in_func && /run_as_target_user/ { saw_target_user = 1 }
    in_func && /curl -o- https:\/\/raw\.githubusercontent\.com\/nvm-sh\/nvm\/v0\.40\.5\/install\.sh \| bash/ { saw_nvm_installer = 1 }
    in_func && /\$NVM_DIR\/nvm\.sh/ { saw_nvm_source = 1 }
    in_func && /nvm install --lts/ { saw_lts_install = 1 }
    in_func && /^}/ { in_func = 0 }
    END {
      exit !(saw_target_user && saw_nvm_installer && saw_nvm_source && saw_lts_install)
    }
  ' "$ROOT_DIR/ubuntu_init.sh"
}

zsh_initialization_installs_ohmyzsh_and_fzf() {
  awk '
    /^initialize_zsh\(\) \{/ { in_func = 1 }
    in_func && /command -v zsh/ { saw_zsh_detection = 1 }
    in_func && /chsh -s "\$zsh_path" "\$TARGET_USER"/ { saw_chsh = 1 }
    in_func && /run_as_target_user zsh -lc/ { saw_zsh_shell = 1 }
    in_func && /raw\.github\.com\/ohmyzsh\/ohmyzsh\/master\/tools\/install\.sh/ { saw_ohmyzsh = 1 }
    in_func && /git clone --depth 1 https:\/\/github\.com\/junegunn\/fzf\.git "\$HOME\/\.fzf"/ { saw_fzf_clone = 1 }
    in_func && /"\$HOME\/\.fzf\/install" --all/ { saw_fzf_install = 1 }
    in_func && /^}/ { in_func = 0 }
    END {
      exit !(saw_zsh_detection && saw_chsh && saw_zsh_shell && saw_ohmyzsh && saw_fzf_clone && saw_fzf_install)
    }
  ' "$ROOT_DIR/ubuntu_init.sh"
}

target_user_commands_use_target_login_shell() {
  awk '
    /^run_as_target_user\(\) \{/ { in_func = 1 }
    in_func && /local target_shell/ { saw_local = 1 }
    in_func && /getent passwd "\$TARGET_USER" \| cut -d: -f7/ { saw_getent = 1 }
    in_func && /SHELL="\$target_shell"/ { saw_shell_env = 1 }
    in_func && /^}/ { in_func = 0 }
    END {
      exit !(saw_local && saw_getent && saw_shell_env)
    }
  ' "$ROOT_DIR/ubuntu_init.sh"
}

readme_lists_node_module() {
  grep -q '| `install_node` | Install nvm and the latest Node.js LTS release |' "$ROOT_DIR/README.md"
}

readme_lists_zsh_module() {
  grep -q "| \`initialize_zsh\` | Set zsh as the target user's shell and install oh-my-zsh and fzf when zsh is available |" "$ROOT_DIR/README.md"
}

has_step_logging() {
  grep -q '^log_step() {' "$ROOT_DIR/ubuntu_init.sh" &&
    grep -q 'log_step "Done."' "$ROOT_DIR/ubuntu_init.sh"
}

disable_welcome_message_uses_target_user() {
  awk '
    /^disable_welcome_message\(\) \{/ { in_func = 1 }
    in_func && /TARGET_HOME/ { saw_target_home = 1 }
    in_func && /TARGET_USER/ { saw_target_user = 1 }
    in_func && /TARGET_GROUP/ { saw_target_group = 1 }
    in_func && /^}/ { in_func = 0 }
    END { exit !(saw_target_home && saw_target_user && saw_target_group) }
  ' "$ROOT_DIR/ubuntu_init.sh"
}

for script in "${SCRIPTS[@]}"; do
  check "$script is executable" test -x "$ROOT_DIR/$script"
  check "$script has valid bash syntax" bash -n "$ROOT_DIR/$script"
done

check "repository has one top-level script" has_single_top_level_script
check "Ubuntu 22.04 is rejected before root check" unsupported_os_fails_before_root_check "$UBUNTU_22_04_OS_RELEASE"
check "Debian 12 is rejected before root check" unsupported_os_fails_before_root_check "$DEBIAN_12_OS_RELEASE"
check "script supports normal user entrypoint" supports_normal_user_entrypoint
check "system changes use sudo helper" system_changes_use_sudo_helper
check "Docker install is idempotent" docker_install_is_idempotent
check "user config targets invoking user" user_config_targets_invoking_user
check "README uses normal user remote command" readme_uses_normal_user_remote_command
check "ubuntu_init.sh has main entrypoint" has_main_entrypoint
check "main installs tools before setting editor" main_installs_tools_before_setting_editor
check "main installs Node after common tools" main_installs_node_after_common_tools
check "main initializes zsh after common tools" main_initializes_zsh_after_common_tools
check "Node install uses nvm latest LTS" node_install_uses_nvm_lts
check "zsh initialization installs oh-my-zsh and fzf" zsh_initialization_installs_ohmyzsh_and_fzf
check "target user commands use target login shell" target_user_commands_use_target_login_shell
check "README lists Node module" readme_lists_node_module
check "README lists zsh module" readme_lists_zsh_module
check "ubuntu_init.sh logs progress" has_step_logging
check "welcome message disable uses target user" disable_welcome_message_uses_target_user

if [ "$failures" -ne 0 ]; then
  exit 1
fi
