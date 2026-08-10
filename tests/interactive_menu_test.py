#!/usr/bin/env python3

import errno
import os
import pty
import re
import select
import shlex
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
    "install_codex",
    "install_code_review_graph",
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
BASE_TOOLS = [
    "install_common_tools",
    "initialize_zsh",
    "set_default_editor",
    "configure_vim",
]
DEVELOPMENT_TOOLS = [
    "install_node",
    "install_codex",
    "install_code_review_graph",
]
DOCKER = ["configure_docker", "install_docker"]
SYSTEM_CONFIGURATION = [
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


def first_render(output: str) -> str:
    _, _, first = output.partition("Select modules to install")
    return first.split("Select modules to install", 1)[0].split("\nRESULT:", 1)[0]


def final_render(output: str) -> str:
    _, _, final = output.rpartition("Select modules to install")
    return final.split("\nRESULT:", 1)[0]


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


def create_main_driver(directory: Path, force_menu_failure: bool = False) -> tuple[Path, Path]:
    driver = directory / "main_driver.sh"
    trace_file = directory / "trace"
    menu_overrides = ""
    if force_menu_failure:
        menu_overrides = """
has_controlling_terminal() { return 0; }
select_modules_interactively() { return 1; }
"""
    driver.write_text(
        script_definitions()
        + menu_overrides
        + f"""
TRACE_FILE={shlex.quote(str(trace_file))}
require_supported_os() {{ :; }}
init_target_user() {{ :; }}
require_sudo() {{ :; }}
for module in "${{MODULE_ORDER[@]}}"; do
  eval "$module() {{ printf '%s\\n' '$module' >>\"$TRACE_FILE\"; }}"
done
main "$@"
"""
    )
    return driver, trace_file


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

    def test_categories_start_collapsed_and_all_modules_selected(self) -> None:
        output, selected = self.run_menu(b"\r")
        self.assertEqual(selected, MODULES)
        self.assertIn("[x] Base tools", output)
        self.assertIn("[x] Development tools", output)
        self.assertNotIn("install_common_tools", first_render(output))

    def test_right_expands_and_left_collapses_category(self) -> None:
        output, _ = self.run_menu(b"\x1b[C\x1b[D\r")
        self.assertIn("install_common_tools", output)
        self.assertGreaterEqual(output.count("Base tools"), 2)
        self.assertNotIn("install_common_tools", final_render(output))

    def test_space_clears_an_entire_category(self) -> None:
        _, selected = self.run_menu(b" \r")
        self.assertEqual(selected, [module for module in MODULES if module not in BASE_TOOLS])

    def test_child_toggle_gives_category_partial_marker(self) -> None:
        output, selected = self.run_menu(b"\x1b[C\x1b[B \r")
        self.assertNotIn("install_common_tools", selected)
        self.assertIn("[-] Base tools", output)

    def test_space_on_clear_action_clears_all_and_focuses_first_category(self) -> None:
        output, selected = self.run_menu(b"\x1b[A \r \r")
        self.assertIn("[ Clear all selections ]", output)
        self.assertNotIn("[x] Clear all selections", output)
        self.assertEqual(selected, BASE_TOOLS)

    def test_empty_selection_is_rejected(self) -> None:
        output, selected = self.run_menu(b"\x1b[A \r \r")
        self.assertIn("Select at least one module.", output)
        self.assertEqual(selected, BASE_TOOLS)

    def test_categories_are_not_command_line_modules(self) -> None:
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), "docker"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown module: docker", result.stderr)

    def test_no_tty_runs_all_and_module_arguments_keep_canonical_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            driver, trace_file = create_main_driver(directory)
            run_all = subprocess.run(
                ["/bin/bash", str(driver)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=True,
                start_new_session=True,
            )
            run_all_trace = trace_file.read_text().splitlines()
            trace_file.unlink()
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
            selected_trace = trace_file.read_text().splitlines()

        self.assertEqual(run_all.stderr, "")
        self.assertEqual(run_all_trace, MODULES)
        self.assertEqual(selected.stderr, "")
        self.assertEqual(
            selected_trace,
            ["install_common_tools", "disable_welcome_message"],
        )

    def test_help_argument_bypasses_menu_in_a_tty(self) -> None:
        status, output = run_pty(["/bin/bash", str(SCRIPT_PATH), "--help"])
        self.assertEqual(status, 0, output)
        self.assertIn("Usage: ubuntu_init.sh", output)
        self.assertNotIn("Use Up/Down", output)

    def test_menu_read_failure_aborts_instead_of_running_all_modules(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            driver, trace_file = create_main_driver(
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
            trace_exists = trace_file.exists()

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(trace_exists)


if __name__ == "__main__":
    unittest.main(verbosity=2)
