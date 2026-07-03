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

run_non_root_check() {
  local mode="$1"
  local script="$2"
  local output
  local status

  set +e
  if [ "$mode" = "direct" ]; then
    output="$(OS_RELEASE_FILE="$UBUNTU_24_04_OS_RELEASE" "$ROOT_DIR/$script" 2>&1)"
  elif [ "$mode" = "bash" ]; then
    output="$(OS_RELEASE_FILE="$UBUNTU_24_04_OS_RELEASE" bash "$ROOT_DIR/$script" 2>&1)"
  else
    output="$(OS_RELEASE_FILE="$UBUNTU_24_04_OS_RELEASE" bash <"$ROOT_DIR/$script" 2>&1)"
  fi
  status=$?

  [ "$status" -eq 1 ] && grep -q "Please run as root" <<<"$output"
}

supported_os_reaches_root_check() {
  local os_release_file="$1"
  local output
  local status

  set +e
  output="$(OS_RELEASE_FILE="$os_release_file" bash "$ROOT_DIR/ubuntu_init.sh" 2>&1)"
  status=$?

  [ "$status" -eq 1 ] && grep -q "Please run as root" <<<"$output"
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

for script in "${SCRIPTS[@]}"; do
  check "$script is executable" test -x "$ROOT_DIR/$script"
  check "$script has valid bash syntax" bash -n "$ROOT_DIR/$script"
  check "$script fails clearly when run directly without root" run_non_root_check direct "$script"
  check "$script fails clearly when run with bash without root" run_non_root_check bash "$script"
  check "$script fails clearly when piped into bash without root" run_non_root_check pipe "$script"
done

check "repository has one top-level script" has_single_top_level_script
check "Ubuntu 22.04 is rejected before root check" unsupported_os_fails_before_root_check "$UBUNTU_22_04_OS_RELEASE"
check "Debian 12 is rejected before root check" unsupported_os_fails_before_root_check "$DEBIAN_12_OS_RELEASE"
check "Ubuntu 24.04 reaches root check" supported_os_reaches_root_check "$UBUNTU_24_04_OS_RELEASE"
check "Ubuntu 24.10 reaches root check" supported_os_reaches_root_check "$UBUNTU_24_10_OS_RELEASE"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
