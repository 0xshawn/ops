#!/usr/bin/env python3

import errno
import os
import pty
import select
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT_DIR / "ubuntu_init.sh"
TASK_SKIPPED = 20


def script_definitions() -> str:
    script_text = SCRIPT_PATH.read_text()
    definitions, separator, trailer = script_text.rpartition('\nmain "$@"')
    if not separator or trailer.strip():
        raise AssertionError('ubuntu_init.sh must end with main "$@"')
    return definitions


def run_driver(command: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temporary_directory:
        driver = Path(temporary_directory) / "task_status_driver.sh"
        driver.write_text(script_definitions() + "\n" + command + "\n")
        return subprocess.run(
            ["/bin/bash", str(driver)],
            stdout=subprocess.PIPE,
            text=True,
            stderr=subprocess.STDOUT,
        )


def run_signaled_task_driver(directory: Path) -> tuple[int, bytes, Path]:
    driver = directory / "signaled_task_driver.sh"
    log_record = directory / "task-log-path"
    driver.write_text(
        script_definitions()
        + f"""
export LOG_RECORD={log_record}
require_supported_os() {{ :; }}
init_target_user() {{ :; }}
require_sudo() {{ :; }}
install_common_tools() {{
  printf '%s\n' "$TASK_LOG_FILE" >"$LOG_RECORD"
  while :; do :; done
}}
main install_common_tools
"""
    )

    pid, fd = pty.fork()
    if pid == 0:
        environment = os.environ.copy()
        environment["TMPDIR"] = str(directory)
        os.execve("/bin/bash", ["/bin/bash", str(driver)], environment)

    output = bytearray()
    signal_sent = False
    deadline = time.monotonic() + 5
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.05)
            if not readable:
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
            if not signal_sent and b"Installing common tools" in output:
                os.kill(pid, signal.SIGTERM)
                signal_sent = True
        else:
            os.kill(pid, signal.SIGKILL)
            raise AssertionError(f"Task process did not terminate:\n{output!r}")
    finally:
        os.close(fd)

    if not signal_sent:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise AssertionError(f"Task spinner was not rendered:\n{output!r}")

    _, wait_status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(wait_status), bytes(output), log_record


class TaskStatusTest(unittest.TestCase):
    def test_success_hides_command_output(self):
        result = run_driver("run_task 'Successful task' bash -c 'echo hidden-output'")
        self.assertEqual(result.returncode, 0)
        self.assertIn("START Successful task", result.stdout)
        self.assertIn("OK Successful task", result.stdout)
        self.assertNotIn("hidden-output", result.stdout)
        self.assertNotIn("\x1b", result.stdout)

    def test_skipped_is_not_a_failure(self):
        result = run_driver(
            f"run_task 'Skipped task' bash -c 'echo hidden-skip; exit {TASK_SKIPPED}'"
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("SKIPPED Skipped task", result.stdout)
        self.assertNotIn("hidden-skip", result.stdout)

    def test_failure_prints_log_and_preserves_status(self):
        result = run_driver("run_task 'Failed task' bash -c 'echo failure-detail; exit 23'")
        self.assertEqual(result.returncode, 23)
        self.assertIn("FAILED Failed task", result.stdout)
        self.assertIn("failure-detail", result.stdout)

    def test_intermediate_module_failure_stops_later_commands(self):
        result = run_driver(
            """
run_as_root() {
  printf 'ROOT:%s\n' "$*" >>"$TRACE_FILE"
  if [ "$*" = "apt update" ]; then
    return 42
  fi
}
TRACE_FILE="$(mktemp)"
if run_task 'Installing common tools' install_common_tools; then
  status=0
else
  status=$?
fi
printf 'STATUS:%s\n' "$status"
cat "$TRACE_FILE"
rm -f "$TRACE_FILE"
"""
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("FAILED Installing common tools", result.stdout)
        self.assertIn("STATUS:42", result.stdout)
        self.assertIn("ROOT:apt update", result.stdout)
        self.assertNotIn("ROOT:apt install", result.stdout)

    def test_root_file_failure_stops_later_service_commands(self):
        result = run_driver(
            """
run_as_root() {
  printf 'ROOT:%s\n' "$*" >>"$TRACE_FILE"
  if [ "$1" = install ]; then
    return 42
  fi
}
TRACE_FILE="$(mktemp)"
if run_task 'Configuring journald' configure_journald; then
  status=0
else
  status=$?
fi
printf 'STATUS:%s\n' "$status"
cat "$TRACE_FILE"
rm -f "$TRACE_FILE"
"""
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("FAILED Configuring journald", result.stdout)
        self.assertIn("STATUS:42", result.stdout)
        self.assertIn("ROOT:install", result.stdout)
        self.assertNotIn("ROOT:systemctl", result.stdout)

    def test_task_state_mutations_are_preserved(self):
        result = run_driver(
            """
id() {
  case "$1" in
    -un) printf '%s\n' test-user ;;
    -gn) printf '%s\n' test-group ;;
    *) return 1 ;;
  esac
}
getent() { printf '%s\n' 'test-user:x:1000:1000::/tmp:/bin/bash'; }
run_task 'Resolving target user' init_target_user
printf 'TARGET:%s:%s:%s\n' "$TARGET_USER" "$TARGET_HOME" "$TARGET_GROUP"
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("TARGET:test-user:/tmp:test-group", result.stdout)

    def test_task_signal_restores_tty_and_removes_log(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            status, output, log_record = run_signaled_task_driver(
                Path(temporary_directory)
            )
            self.assertTrue(log_record.exists(), output)
            task_log = Path(log_record.read_text().strip())
            self.assertEqual(status, 130, output)
            self.assertIn(b"\x1b[?25l", output)
            self.assertIn(b"\x1b[?25h", output)
            self.assertFalse(task_log.exists(), output)

    def test_die_stops_task_before_later_commands(self):
        result = run_driver(
            """
is_root() { return 0; }
command() {
  if [ "$1" = "-v" ] && [ "${2:-}" = "docker" ]; then
    return 1
  fi
  builtin command "$@"
}
wget() { printf '#!/usr/bin/env bash\\nexit 0\\n'; }
run_as_root() {
  case "$1" in
    bash) "$@" ;;
    systemctl) systemctl_ran=1 ;;
  esac
}
systemctl_ran=0
if run_task 'Installing Docker' install_docker; then
  status=0
else
  status=$?
fi
printf 'STATUS:%s\\nSYSTEMCTL:%s\\n' "$status" "$systemctl_ran"
"""
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("FAILED Installing Docker", result.stdout)
        self.assertIn(
            "Docker installation completed without installing the docker command.",
            result.stdout,
        )
        self.assertIn("STATUS:1", result.stdout)
        self.assertIn("SYSTEMCTL:0", result.stdout)


if __name__ == "__main__":
    unittest.main()
