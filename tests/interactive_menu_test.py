#!/usr/bin/env python3

import errno
import os
import pty
import re
import select
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT_DIR / "ubuntu_init.sh"
MODULES = [
    "install_common_tools",
    "initialize_zsh",
    "install_node",
    "set_default_editor",
    "configure_docker",
    "install_docker",
    "configure_vim",
    "configure_passwordless_sudo",
    "configure_journald",
    "configure_logrotate",
    "disable_apt_daily_timers",
    "disable_welcome_message",
]
ANSI_ESCAPE = re.compile(rb"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")


def script_definitions() -> str:
    script_text = SCRIPT_PATH.read_text()
    definitions, separator, trailer = script_text.rpartition('\nmain "$@"')
    if not separator or trailer.strip():
        raise AssertionError('ubuntu_init.sh must end with main "$@"')
    return definitions


def clean_output(output: bytes) -> str:
    return ANSI_ESCAPE.sub(b"", output).decode(errors="replace").replace("\r", "")


def run_pty(argv: list[str], input_bytes: bytes = b"", wait_for: bytes | None = None) -> tuple[int, str]:
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(argv[0], argv, os.environ.copy())

    output = bytearray()
    deadline = time.monotonic() + 5
    sent_input = wait_for is None
    if sent_input and input_bytes:
        os.write(fd, input_bytes)

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

            if not sent_input and wait_for in output:
                if input_bytes:
                    os.write(fd, input_bytes)
                sent_input = True
        else:
            os.kill(pid, signal.SIGKILL)
            raise AssertionError(f"PTY command timed out:\n{clean_output(bytes(output))}")
    finally:
        os.close(fd)

    _, wait_status = os.waitpid(pid, 0)
    status = os.waitstatus_to_exitcode(wait_status)
    text = clean_output(bytes(output))
    if wait_for is not None and not sent_input:
        raise AssertionError(f"PTY prompt was not shown:\n{text}")
    return status, text


def create_menu_driver(directory: Path) -> Path:
    driver = directory / "menu_driver.sh"
    driver.write_text(
        script_definitions()
        + "\nselect_modules_interactively\n"
        + "printf '\\nRESULT:%s\\n' \"$INTERACTIVE_SELECTED_MODULES\"\n"
    )
    return driver


def create_main_driver(directory: Path, force_menu_failure: bool = False) -> Path:
    driver = directory / "main_driver.sh"
    menu_overrides = ""
    if force_menu_failure:
        menu_overrides = """
has_controlling_terminal() { return 0; }
select_modules_interactively() { return 1; }
"""
    driver.write_text(
        script_definitions()
        + menu_overrides
        + """
require_supported_os() { :; }
init_target_user() { :; }
require_sudo() { :; }
for module in "${MODULE_ORDER[@]}"; do
  eval "$module() { printf 'RUN:%s\\n' '$module'; }"
done
main "$@"
"""
    )
    return driver


def selected_modules(output: str) -> list[str]:
    matches = re.findall(r"^RESULT:(.*)$", output, flags=re.MULTILINE)
    if not matches:
        raise AssertionError(f"Menu result was not printed:\n{output}")
    return matches[-1].split()


class InteractiveMenuTest(unittest.TestCase):
    def run_menu(self, keys: bytes) -> tuple[str, list[str]]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            driver = create_menu_driver(Path(temporary_directory))
            status, output = run_pty(
                ["/bin/bash", str(driver)],
                input_bytes=keys,
                wait_for=b"Use Up/Down",
            )
        self.assertEqual(status, 0, output)
        return output, selected_modules(output)

    def test_enter_accepts_all_modules_selected_by_default(self) -> None:
        _, selected = self.run_menu(b"\r")
        self.assertEqual(selected, MODULES)

    def test_up_down_and_space_toggle_modules(self) -> None:
        _, selected = self.run_menu(b"\x1b[B \x1b[A \r")
        self.assertEqual(selected, MODULES[2:])

    def test_empty_selection_is_rejected(self) -> None:
        keys = b" " + (b"\x1b[B " * (len(MODULES) - 1)) + b"\r \r"
        output, selected = self.run_menu(keys)
        self.assertIn("Select at least one module.", output)
        self.assertEqual(selected, ["disable_welcome_message"])

    def test_no_tty_runs_all_and_module_arguments_keep_canonical_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            driver = create_main_driver(Path(temporary_directory))
            run_all = subprocess.run(
                ["/bin/bash", str(driver)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=True,
                start_new_session=True,
            )
            selected = subprocess.run(
                [
                    "/bin/bash",
                    str(driver),
                    "disable_welcome_message",
                    "install_common_tools",
                ],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=True,
                start_new_session=True,
            )

        self.assertEqual(
            re.findall(r"^RUN:(.*)$", run_all.stdout, flags=re.MULTILINE),
            MODULES,
        )
        self.assertEqual(
            re.findall(r"^RUN:(.*)$", selected.stdout, flags=re.MULTILINE),
            ["install_common_tools", "disable_welcome_message"],
        )

    def test_help_argument_bypasses_menu_in_a_tty(self) -> None:
        status, output = run_pty(["/bin/bash", str(SCRIPT_PATH), "--help"])
        self.assertEqual(status, 0, output)
        self.assertIn("Usage: ubuntu_init.sh", output)
        self.assertNotIn("Use Up/Down", output)

    def test_menu_read_failure_aborts_instead_of_running_all_modules(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            driver = create_main_driver(
                Path(temporary_directory),
                force_menu_failure=True,
            )
            result = subprocess.run(
                ["/bin/bash", str(driver)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                start_new_session=True,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("RUN:", result.stdout)

if __name__ == "__main__":
    unittest.main(verbosity=2)
