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


def run_signaled_task_driver(
    directory: Path,
    task_signal: signal.Signals,
    *,
    repeat_signal: bool = False,
    term_resistant_descendant: bool = False,
    term_resistant_tree_depth: int = 0,
) -> tuple[int, bytes, Path, list[int], float]:
    driver = directory / "signaled_task_driver.sh"
    log_record = directory / "task-log-path"
    external_pid_record = directory / "external-pid"
    long_command = directory / "long-command.sh"
    expected_pid_count = 1
    if term_resistant_tree_depth:
        expected_pid_count = term_resistant_tree_depth * 2 + 1
        resistant_command = directory / "term-resistant-tree.py"
        resistant_command.write_text(
            "import os\n"
            "import signal\n"
            "import subprocess\n"
            "import sys\n"
            "\n"
            "pid_file = sys.argv[1]\n"
            "depth = int(sys.argv[2])\n"
            "for task_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):\n"
            "    signal.signal(task_signal, signal.SIG_IGN)\n"
            "with open(pid_file, 'a') as record:\n"
            "    record.write(f'{os.getpid()}\\n')\n"
            "if depth:\n"
            "    subprocess.Popen([sys.executable, __file__, pid_file, '0'])\n"
            "    subprocess.Popen([sys.executable, __file__, pid_file, str(depth - 1)])\n"
            "while True:\n"
            "    signal.pause()\n"
        )
        long_command.write_text(
            "#!/bin/bash\n"
            f"exec python3 {resistant_command} \"$EXTERNAL_PID_RECORD\" "
            f"{term_resistant_tree_depth}\n"
        )
    elif term_resistant_descendant:
        resistant_command = directory / "term-resistant-command.py"
        resistant_command.write_text(
            "import os\n"
            "import signal\n"
            "import sys\n"
            "\n"
            "for task_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):\n"
            "    signal.signal(task_signal, signal.SIG_IGN)\n"
            "with open(sys.argv[1], 'w') as pid_file:\n"
            "    pid_file.write(f'{os.getpid()}\\n')\n"
            "while True:\n"
            "    signal.pause()\n"
        )
        long_command.write_text(
            "#!/bin/bash\n"
            f"python3 {resistant_command} \"$EXTERNAL_PID_RECORD\"\n"
        )
    else:
        long_command.write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' \"$$\" >\"$EXTERNAL_PID_RECORD\"\n"
            "exec /bin/sleep 30\n"
        )
    long_command.chmod(0o755)
    driver.write_text(
        script_definitions()
        + f"""
export LOG_RECORD={log_record}
export EXTERNAL_PID_RECORD={external_pid_record}
require_supported_os() {{ :; }}
init_target_user() {{ :; }}
require_sudo() {{ :; }}
install_common_tools() {{
  printf '%s\n' "$TASK_LOG_FILE" >"$LOG_RECORD"
  {long_command}
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
    signal_sent_at = None
    repeated_signal_sent = False
    wait_status = None
    deadline = time.monotonic() + 7

    def recorded_pids() -> list[int]:
        if not external_pid_record.exists():
            return []
        return [int(value) for value in external_pid_record.read_text().split()]

    def kill_recorded_pids() -> None:
        for recorded_pid in recorded_pids():
            try:
                os.kill(recorded_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.05)
            if readable:
                try:
                    chunk = os.read(fd, 4096)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""
                output.extend(chunk)
            if (
                not signal_sent
                and b"Installing common tools" in output
                and log_record.exists()
                and len(recorded_pids()) >= expected_pid_count
            ):
                os.kill(pid, task_signal)
                signal_sent = True
                signal_sent_at = time.monotonic()
            if (
                repeat_signal
                and signal_sent
                and not repeated_signal_sent
                and signal_sent_at is not None
                and time.monotonic() - signal_sent_at >= 0.1
            ):
                try:
                    os.kill(pid, task_signal)
                except ProcessLookupError:
                    pass
                repeated_signal_sent = True
            if signal_sent:
                finished_pid, candidate_status = os.waitpid(pid, os.WNOHANG)
                if finished_pid == pid:
                    wait_status = candidate_status
                    break
        else:
            os.kill(pid, signal.SIGKILL)
            kill_recorded_pids()
            os.waitpid(pid, 0)
            raise AssertionError(f"Task process did not terminate:\n{output!r}")

        drain_deadline = time.monotonic() + 0.3
        while time.monotonic() < drain_deadline:
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
    finally:
        os.close(fd)

    if not signal_sent:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        raise AssertionError(f"Task spinner was not rendered:\n{output!r}")

    if wait_status is None:
        _, wait_status = os.waitpid(pid, 0)
    external_pids = recorded_pids()
    assert signal_sent_at is not None
    return (
        os.waitstatus_to_exitcode(wait_status),
        bytes(output),
        log_record,
        external_pids,
        time.monotonic() - signal_sent_at,
    )


class TaskStatusTest(unittest.TestCase):
    def test_spinner_uses_single_character_frames(self):
        result = run_driver(
            """
spinner_sleep_count=0
sleep() {
  spinner_sleep_count=$((spinner_sleep_count + 1))
  [ "$spinner_sleep_count" -lt 4 ] || exit 0
}
render_spinner "Task"
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "\n| Task\n/ Task\n- Task\n\\ Task")

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

    def test_task_signals_preserve_status_and_cleanup(self):
        expected_statuses = {
            signal.SIGINT: 130,
            signal.SIGTERM: 143,
            signal.SIGHUP: 129,
        }
        for task_signal, expected_status in expected_statuses.items():
            with self.subTest(task_signal=task_signal):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    status, output, log_record, external_pids, _ = run_signaled_task_driver(
                        Path(temporary_directory), task_signal
                    )
                    external_pid = external_pids[0]
                    self.assertTrue(log_record.exists(), output)
                    task_log = Path(log_record.read_text().strip())
                    self.assertEqual(status, expected_status, output)
                    self.assertIn(b"\x1b[?25l", output)
                    self.assertIn(b"\x1b[?25h", output)
                    self.assertFalse(task_log.exists(), output)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(external_pid, 0)
                    after_restore = output.rsplit(b"\x1b[?25h", 1)[-1]
                    self.assertNotIn(b"Installing common tools", after_restore)

    def test_task_signal_kills_term_resistant_descendant_before_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            status, output, log_record, external_pids, _ = run_signaled_task_driver(
                Path(temporary_directory),
                signal.SIGTERM,
                term_resistant_descendant=True,
            )
            external_pid = external_pids[0]
            self.assertTrue(log_record.exists(), output)
            task_log = Path(log_record.read_text().strip())
            try:
                self.assertEqual(status, 143, output)
                with self.assertRaises(ProcessLookupError):
                    os.kill(external_pid, 0)
                self.assertFalse(task_log.exists(), output)
            finally:
                try:
                    os.kill(external_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_repeated_signal_does_not_interrupt_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            external_pids: list[int] = []
            try:
                status, output, log_record, external_pids, _ = run_signaled_task_driver(
                    Path(temporary_directory),
                    signal.SIGTERM,
                    repeat_signal=True,
                    term_resistant_descendant=True,
                )
                self.assertEqual(status, 143, output)
                self.assertIn(b"\x1b[?25h", output)
                self.assertFalse(Path(log_record.read_text().strip()).exists(), output)
                with self.assertRaises(ProcessLookupError):
                    os.kill(external_pids[0], 0)
            finally:
                for external_pid in external_pids:
                    try:
                        os.kill(external_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_task_shutdown_uses_one_deadline_for_many_deep_processes(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            external_pids: list[int] = []
            try:
                status, output, log_record, external_pids, elapsed = (
                    run_signaled_task_driver(
                        Path(temporary_directory),
                        signal.SIGTERM,
                        term_resistant_tree_depth=12,
                    )
                )
                self.assertEqual(status, 143, output)
                self.assertEqual(len(external_pids), 25)
                self.assertLess(elapsed, 4.5, output)
                self.assertFalse(Path(log_record.read_text().strip()).exists(), output)

                remaining = list(external_pids)
                reap_deadline = time.monotonic() + 1
                while remaining and time.monotonic() < reap_deadline:
                    survivors = []
                    for external_pid in remaining:
                        try:
                            os.kill(external_pid, 0)
                            survivors.append(external_pid)
                        except ProcessLookupError:
                            pass
                    remaining = survivors
                    time.sleep(0.02)
                self.assertEqual(remaining, [], output)
            finally:
                for external_pid in external_pids:
                    try:
                        os.kill(external_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_inspection_failure_is_retained_as_unverified_cleanup(self):
        result = run_driver(
            """
inspection_attempted=0
mock_time=0
task_time_milliseconds() {
  TASK_NOW_MILLISECONDS="$mock_time"
  mock_time=$((mock_time + 100))
}
task_process_details() {
  if [ "$inspection_attempted" -eq 1 ]; then
    return "$TASK_PROCESS_GONE"
  fi
  TASK_PROCESS_START=456
  TASK_PROCESS_STATE=S
}
task_process_children() {
  TASK_PROCESS_CHILDREN=()
  inspection_attempted=1
  return "$TASK_PROCESS_UNINSPECTABLE"
}
signal_task_process() { :; }
sleep() { :; }
if terminate_task_process_tree 123 456; then
  status=0
else
  status=$?
fi
printf 'STATUS:%s\n' "$status"
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("STATUS:1", result.stdout)
        self.assertIn("unable to verify stopped task process 123", result.stdout)

    def test_uninspectable_process_metadata_is_not_treated_as_gone(self):
        result = run_driver(
            """
task_process_details() { return "$TASK_PROCESS_UNINSPECTABLE"; }
if terminate_task_process_tree 123 456; then
  status=0
else
  status=$?
fi
printf 'STATUS:%s\n' "$status"
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("STATUS:1", result.stdout)
        self.assertIn("unable to verify stopped task process 123", result.stdout)

    def test_cleanup_does_not_wait_after_unverified_shutdown(self):
        result = run_driver(
            """
TASK_COMMAND_PID=123
terminate_task_process_tree() { return 1; }
wait() { printf 'UNBOUNDED-WAIT\n'; }
cleanup_task_status
printf 'CLEANED\n'
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("CLEANED", result.stdout)
        self.assertNotIn("UNBOUNDED-WAIT", result.stdout)

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
    systemctl) printf 'ran\\n' >"$SYSTEMCTL_FILE" ;;
  esac
}
SYSTEMCTL_FILE="$(mktemp)"
if run_task 'Installing Docker' install_docker; then
  status=0
else
  status=$?
fi
systemctl_ran=0
[ ! -s "$SYSTEMCTL_FILE" ] || systemctl_ran=1
rm -f "$SYSTEMCTL_FILE"
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
