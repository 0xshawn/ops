#!/usr/bin/env python3

import shlex
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
                 existing_keys: str = "") -> subprocess.CompletedProcess[str]:
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
    printf 'alice:x:1001:1001::/home/alice:/bin/bash\n'
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

    def test_ssh_helper_uses_safe_modes_ownership_and_exact_key_match(self) -> None:
        script = SCRIPT_PATH.read_text()
        self.assertIn('mkdir -p "$ssh_dir"', script)
        self.assertIn('chmod 0700 "$ssh_dir"', script)
        self.assertIn('grep -Fqx -- "$public_key" "$authorized_keys"', script)
        self.assertIn('printf "%s\\n" "$public_key" >>"$authorized_keys"', script)
        self.assertIn('chmod 0600 "$authorized_keys"', script)
        self.assertIn('chown "$username:$group" "$ssh_dir" "$authorized_keys"', script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
