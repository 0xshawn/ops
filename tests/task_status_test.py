#!/usr/bin/env python3

import subprocess
import tempfile
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
