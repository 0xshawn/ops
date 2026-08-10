#!/usr/bin/env python3

import shlex
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


def run_installer(
    installer: str,
    existing: set[str],
    command_available_after: bool,
    installer_exit: int = 0,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    with tempfile.TemporaryDirectory() as temporary_directory:
        directory = Path(temporary_directory)
        driver = directory / "developer_tools_driver.sh"
        trace_file = directory / "trace"
        available_file = directory / "available"
        available_file.write_text("".join(f"{name}\n" for name in existing))

        trace_path = shlex.quote(str(trace_file))
        available_path = shlex.quote(str(available_file))
        driver.write_text(
            script_definitions()
            + f"""
TRACE_FILE={trace_path}
AVAILABLE_FILE={available_path}
COMMAND_AVAILABLE_AFTER={int(command_available_after)}
INSTALLER_EXIT={installer_exit}

is_available() {{
  grep -Fxq "$1" "$AVAILABLE_FILE"
}}

target_user_has_command() {{
  printf 'CHECK:%s\\n' "$1" >>"$TRACE_FILE"
  is_available "$1"
}}

install_node() {{
  printf 'INSTALL_NODE\\n' >>"$TRACE_FILE"
  printf 'node\\n' >>"$AVAILABLE_FILE"
}}

run_as_root() {{
  shift
  printf 'APT:%s\\n' "$*" >>"$TRACE_FILE"
}}

curl() {{
  return 0
}}

sh() {{
  cat >/dev/null
  printf 'CODEX_INSTALLER\\n' >>"$TRACE_FILE"
  if [ "$INSTALLER_EXIT" -eq 0 ] && [ "$COMMAND_AVAILABLE_AFTER" -eq 1 ]; then
    printf 'codex\\n' >>"$AVAILABLE_FILE"
  fi
  return "$INSTALLER_EXIT"
}}

export -f curl sh
export TRACE_FILE AVAILABLE_FILE COMMAND_AVAILABLE_AFTER INSTALLER_EXIT

run_as_target_user() {{
  case "$1" in
    bash)
      "$@"
      ;;
    pipx)
      printf 'TARGET:%s\\n' "$*" >>"$TRACE_FILE"
      if [ "$INSTALLER_EXIT" -eq 0 ] && [ "$COMMAND_AVAILABLE_AFTER" -eq 1 ]; then
        printf 'code-review-graph\\n' >>"$AVAILABLE_FILE"
      fi
      return "$INSTALLER_EXIT"
      ;;
    *)
      return 99
      ;;
  esac
}}

{installer}
"""
        )
        result = subprocess.run(
            ["/bin/bash", str(driver)],
            capture_output=True,
            text=True,
        )
        trace = trace_file.read_text().splitlines() if trace_file.exists() else []
    return result, trace


def run_codex(
    existing: set[str],
    codex_available_after: bool = False,
    installer_exit: int = 0,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    return run_installer(
        "install_codex",
        existing,
        codex_available_after,
        installer_exit,
    )


def run_graph(
    existing: set[str],
    graph_available_after: bool = False,
    installer_exit: int = 0,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    return run_installer(
        "install_code_review_graph",
        existing,
        graph_available_after,
        installer_exit,
    )


class DeveloperToolsInstallTest(unittest.TestCase):
    def test_codex_skips_when_present(self) -> None:
        result, trace = run_codex(existing={"codex", "node"})
        self.assertEqual(result.returncode, TASK_SKIPPED)
        self.assertNotIn("INSTALL_NODE", trace)
        self.assertNotIn("CODEX_INSTALLER", trace)

    def test_codex_installs_node_only_when_missing(self) -> None:
        result, trace = run_codex(existing=set(), codex_available_after=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(trace.index("INSTALL_NODE"), trace.index("CODEX_INSTALLER"))

    def test_codex_does_not_install_existing_node(self) -> None:
        result, trace = run_codex(existing={"node"}, codex_available_after=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("INSTALL_NODE", trace)

    def test_codex_rejects_missing_command_after_installer(self) -> None:
        result, _ = run_codex(existing={"node"}, codex_available_after=False)
        self.assertNotEqual(result.returncode, 0)

    def test_codex_installer_failure_propagates(self) -> None:
        result, trace = run_codex(
            existing={"node"}, codex_available_after=True, installer_exit=42
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(trace.count("CHECK:codex"), 1)

    def test_graph_skips_when_present(self) -> None:
        result, trace = run_graph(existing={"code-review-graph", "pipx"})
        self.assertEqual(result.returncode, TASK_SKIPPED)
        self.assertNotIn("APT:update", trace)
        self.assertNotIn("PIPX_INSTALL", trace)
        self.assertNotIn("TARGET:pipx install code-review-graph", trace)

    def test_graph_installs_missing_pipx_then_package_as_target_user(self) -> None:
        result, trace = run_graph(existing=set(), graph_available_after=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("APT:update", trace)
        self.assertIn("APT:install -y pipx", trace)
        self.assertIn("TARGET:pipx install code-review-graph", trace)

    def test_graph_rejects_missing_command_after_install(self) -> None:
        result, _ = run_graph(existing={"pipx"}, graph_available_after=False)
        self.assertNotEqual(result.returncode, 0)

    def test_graph_installer_failure_propagates(self) -> None:
        result, trace = run_graph(
            existing={"pipx"}, graph_available_after=True, installer_exit=42
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(trace.count("CHECK:code-review-graph"), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
