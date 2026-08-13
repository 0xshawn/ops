#!/usr/bin/env python3

import shlex
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT_DIR / "ubuntu_init.sh"


def script_definitions() -> str:
    definitions, separator, trailer = SCRIPT_PATH.read_text().rpartition('\nmain "$@"')
    if not separator or trailer.strip():
        raise AssertionError('ubuntu_init.sh must end with main "$@"')
    return definitions


class UserSetupTest(unittest.TestCase):
    def run_case(self, inputs: list[str], account_exists: bool = False, docker_exists: bool = True,
                 existing_keys: str = "", uid: int = 1001) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            trace = directory / "trace"
            keys = directory / "authorized_keys"
            keys.write_text(existing_keys)
            quoted_inputs = " ".join(shlex.quote(item) for item in inputs)
            driver = directory / "driver.sh"
            driver.write_text(script_definitions() + f'''
TRACE={shlex.quote(str(trace))}
TEST_KEYS={shlex.quote(str(keys))}
ACCOUNT_EXISTS={int(account_exists)}
INPUTS=({quoted_inputs})
INPUT_INDEX=0
has_controlling_terminal() {{ return 0; }}
read_user_setup_input() {{
  REPLY="${{INPUTS[$INPUT_INDEX]}}"
  INPUT_INDEX=$((INPUT_INDEX + 1))
}}
getent() {{
  if [ "$1" = passwd ]; then
    [ "$ACCOUNT_EXISTS" -eq 1 ] || return 2
    printf 'alice:x:{uid}:1001::/home/alice:/bin/bash\n'
  elif [ "$2" = docker ]; then
    [ "{int(docker_exists)}" -eq 1 ]
  else
    printf 'alice:x:1001:\n'
  fi
}}
id() {{ [ "$1" = -gn ] && printf 'alice\n'; }}
run_as_root() {{
  printf '%q ' "$@" >>"$TRACE"; printf '\n' >>"$TRACE"
  [ "$1" != adduser ] || ACCOUNT_EXISTS=1
}}
configure_user_ssh_key() {{
  printf 'SSH %s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$TRACE"
  grep -Fxq -- "$4" "$TEST_KEYS" || printf '%s\n' "$4" >>"$TEST_KEYS"
}}
set +e
create_user
status=$?
set -e
printf 'STATUS=%s\n' "$status"
printf '%s' "$(cat "$TRACE" 2>/dev/null || true)"
printf 'KEYS_BEGIN\n'; cat "$TEST_KEYS"; printf 'KEYS_END\n'
''')
            return subprocess.run(["/bin/bash", str(driver)], capture_output=True, text=True)

    def test_empty_username_skips(self) -> None:
        result = self.run_case([""])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STATUS=20", result.stdout)
        self.assertNotIn("adduser", result.stdout)

    def test_unavailable_terminal_skips(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            driver = Path(directory) / "driver.sh"
            driver.write_text(script_definitions() + "\nhas_controlling_terminal() { return 1; }\nset +e\ncreate_user\necho STATUS=$?\n")
            result = subprocess.run(["/bin/bash", str(driver)], capture_output=True, text=True)
        self.assertIn("STATUS=20", result.stdout)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_retries_invalid_values_and_configures_new_user(self) -> None:
        key = "ssh-ed25519 AAAATEST alice@example"
        result = self.run_case(["Bad User", "alice", "not-a-key", key])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Invalid username", result.stderr)
        self.assertIn("Invalid SSH public key", result.stderr)
        self.assertIn("adduser --disabled-password --gecos '' alice", result.stdout)
        self.assertIn("usermod -aG sudo alice", result.stdout)
        self.assertIn("usermod -aG docker alice", result.stdout)
        self.assertIn(f"SSH alice /home/alice alice {key}", result.stdout)

    def test_existing_user_without_docker_group_or_key_is_reused(self) -> None:
        result = self.run_case(["alice", ""], account_exists=True, docker_exists=False)
        self.assertNotIn("adduser", result.stdout)
        self.assertIn("usermod -aG sudo alice", result.stdout)
        self.assertNotIn("usermod -aG docker", result.stdout)
        self.assertNotIn("SSH alice", result.stdout)

    def test_duplicate_key_is_preserved_once(self) -> None:
        key = "ssh-rsa AAAATEST existing"
        result = self.run_case(["alice", key], account_exists=True, existing_keys=key + "\n")
        self.assertEqual(result.stdout.count(key), 2)  # one trace entry and one stored key

    def test_root_and_system_accounts_are_rejected_before_mutation(self) -> None:
        for uid in (0, 999):
            with self.subTest(uid=uid):
                result = self.run_case(["alice", ""], account_exists=True, uid=uid)
                self.assertIn("STATUS=1", result.stdout)
                self.assertNotIn("usermod", result.stdout)

    def run_real_ssh_helper(self, home: Path, key: str) -> subprocess.CompletedProcess[str]:
        driver = home.parent / "ssh_driver.sh"
        driver.write_text(script_definitions() + f'''
run_as_root() {{ "$@"; }}
configure_user_ssh_key {shlex.quote(os.getlogin() if os.isatty(0) else subprocess.check_output(["id", "-un"], text=True).strip())} {shlex.quote(str(home))} {shlex.quote(subprocess.check_output(["id", "-gn"], text=True).strip())} {shlex.quote(key)}
''')
        return subprocess.run(["/bin/bash", str(driver)], capture_output=True, text=True)

    def test_real_ssh_helper_appends_once_and_sets_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            home = Path(temporary_directory) / "home"
            home.mkdir()
            ssh_dir = home / ".ssh"
            ssh_dir.mkdir()
            keys = ssh_dir / "authorized_keys"
            keys.write_text("ssh-rsa OLD existing\n")
            key = "ssh-ed25519 NEW test"
            first = self.run_real_ssh_helper(home, key)
            second = self.run_real_ssh_helper(home, key)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(keys.read_text().splitlines(), ["ssh-rsa OLD existing", key])
            self.assertEqual(ssh_dir.stat().st_mode & 0o777, 0o700)
            self.assertEqual(keys.stat().st_mode & 0o777, 0o600)

    def test_real_ssh_helper_rejects_symlinks_without_mutation(self) -> None:
        for link_name in (".ssh", "authorized_keys"):
            with self.subTest(link_name=link_name), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                home = root / "home"
                home.mkdir()
                target = root / "target"
                target.write_text("unchanged\n")
                if link_name == ".ssh":
                    (home / ".ssh").symlink_to(root)
                else:
                    (home / ".ssh").mkdir()
                    (home / ".ssh" / "authorized_keys").symlink_to(target)
                result = self.run_real_ssh_helper(home, "ssh-ed25519 NEW test")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(target.read_text(), "unchanged\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
