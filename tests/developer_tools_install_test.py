#!/usr/bin/env python3

import os
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
    node_exit: int = 0,
    apt_update_exit: int = 0,
    through_run_task: bool = False,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    with tempfile.TemporaryDirectory() as temporary_directory:
        directory = Path(temporary_directory)
        driver = directory / "developer_tools_driver.sh"
        trace_file = directory / "trace"
        available_file = directory / "available"
        target_home = directory / "home"
        target_home.mkdir()
        available_file.write_text("".join(f"{name}\n" for name in existing))

        trace_path = shlex.quote(str(trace_file))
        available_path = shlex.quote(str(available_file))
        target_home_path = shlex.quote(str(target_home))
        driver.write_text(
            script_definitions()
            + f"""
TRACE_FILE={trace_path}
AVAILABLE_FILE={available_path}
TARGET_HOME={target_home_path}
COMMAND_AVAILABLE_AFTER={int(command_available_after)}
INSTALLER_EXIT={installer_exit}
NODE_EXIT={node_exit}
APT_UPDATE_EXIT={apt_update_exit}

is_available() {{
  grep -Fxq "$1" "$AVAILABLE_FILE"
}}

target_user_has_command() {{
  printf 'CHECK:%s\\n' "$1" >>"$TRACE_FILE"
  is_available "$1"
}}

install_node() {{
  printf 'INSTALL_NODE\\n' >>"$TRACE_FILE"
  if [ "$NODE_EXIT" -ne 0 ]; then
    return "$NODE_EXIT"
  fi
  printf 'node\\n' >>"$AVAILABLE_FILE"
}}

run_as_root() {{
  shift
  printf 'APT:%s\\n' "$*" >>"$TRACE_FILE"
  if [ "$*" = update ] && [ "$APT_UPDATE_EXIT" -ne 0 ]; then
    return "$APT_UPDATE_EXIT"
  fi
}}

curl() {{
  return 0
}}

sh() {{
  input_hex=$(od -An -tx1 | tr -d ' \\n')
  printf 'CODEX_INPUT:%s\\n' "$input_hex" >>"$TRACE_FILE"
  printf 'CODEX_INSTALLER\\n' >>"$TRACE_FILE"
  if [ "$INSTALLER_EXIT" -eq 0 ] && [ "$COMMAND_AVAILABLE_AFTER" -eq 1 ]; then
    printf 'codex\\n' >>"$AVAILABLE_FILE"
  fi
  return "$INSTALLER_EXIT"
}}

export -f curl sh
export TRACE_FILE AVAILABLE_FILE COMMAND_AVAILABLE_AFTER INSTALLER_EXIT NODE_EXIT APT_UPDATE_EXIT

run_as_target_user() {{
  case "$1" in
    bash)
      status=0
      HOME="$TARGET_HOME" "$@" || status=$?
      count=$(grep -Fxc 'export PATH="$HOME/.local/bin:$PATH"' "$TARGET_HOME/.zshrc" 2>/dev/null || true)
      printf 'LOCAL_BIN_PATH_COUNT:%s\\n' "$count" >>"$TRACE_FILE"
      return "$status"
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

{"run_task 'Developer tool installer' " if through_run_task else ""}{installer}
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
    node_exit: int = 0,
    through_run_task: bool = False,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    return run_installer(
        "install_codex",
        existing,
        codex_available_after,
        installer_exit,
        node_exit=node_exit,
        through_run_task=through_run_task,
    )


def run_graph(
    existing: set[str],
    graph_available_after: bool = False,
    installer_exit: int = 0,
    apt_update_exit: int = 0,
    through_run_task: bool = False,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    return run_installer(
        "install_code_review_graph",
        existing,
        graph_available_after,
        installer_exit,
        apt_update_exit=apt_update_exit,
        through_run_task=through_run_task,
    )


def run_graph_with_user_local_pipx_under_sudo() -> tuple[
    subprocess.CompletedProcess[str], list[str]
]:
    with tempfile.TemporaryDirectory() as temporary_directory:
        directory = Path(temporary_directory)
        target_home = directory / "home"
        local_bin = target_home / ".local" / "bin"
        local_bin.mkdir(parents=True)
        invoking_bin = directory / "invoking-bin"
        invoking_bin.mkdir()
        for command in ("bash", "cut"):
            (invoking_bin / command).symlink_to(Path("/usr/bin") / command)
        (invoking_bin / "getent").write_text(
            "#!/bin/bash\n"
            f"printf '%s\\n' 'test-user:x:1000:1000::{target_home}:/bin/bash'\n"
        )
        (invoking_bin / "id").write_text(
            "#!/bin/bash\n"
            "case \"$1\" in\n"
            "  -u) printf '%s\\n' 1000 ;;\n"
            "  -un) printf '%s\\n' invoking-user ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n"
        )
        (invoking_bin / "getent").chmod(0o755)
        (invoking_bin / "id").chmod(0o755)
        sudo = directory / "sudo"
        sudo.write_text(
            "#!/bin/bash\n"
            "[ \"$1\" = -H ] || exit 91\n"
            "[ \"$2\" = -u ] || exit 92\n"
            "[ \"$3\" = test-user ] || exit 93\n"
            "[ \"$4\" = env ] || exit 94\n"
            "shift 4\n"
            "exec /usr/bin/env \"$@\"\n"
        )
        sudo.chmod(0o755)
        trace_file = directory / "trace"
        pipx = local_bin / "pipx"
        pipx.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" >>\"$TRACE_FILE\"\n"
            "/usr/bin/touch \"$HOME/.local/bin/code-review-graph\"\n"
            "/usr/bin/chmod +x \"$HOME/.local/bin/code-review-graph\"\n"
        )
        pipx.chmod(0o755)

        driver = directory / "user_local_pipx_driver.sh"
        driver.write_text(
            script_definitions()
            + f"""
TARGET_USER=test-user
TARGET_HOME={shlex.quote(str(target_home))}
export TRACE_FILE={shlex.quote(str(trace_file))}
PATH={shlex.quote(str(invoking_bin))}
install_code_review_graph
"""
        )
        environment = os.environ.copy()
        environment["SUDO_BIN"] = str(sudo)
        result = subprocess.run(
            ["/bin/bash", str(driver)],
            capture_output=True,
            text=True,
            env=environment,
        )
        trace = trace_file.read_text().splitlines() if trace_file.exists() else []
    return result, trace


class DeveloperToolsInstallTest(unittest.TestCase):
    def test_codex_skips_when_present(self) -> None:
        result, trace = run_codex(existing={"codex", "node"})
        self.assertEqual(result.returncode, TASK_SKIPPED)
        self.assertIn("LOCAL_BIN_PATH_COUNT:1", trace)
        self.assertNotIn("INSTALL_NODE", trace)
        self.assertNotIn("CODEX_INSTALLER", trace)

    def test_local_bin_path_configuration_is_idempotent(self) -> None:
        result, trace = run_installer(
            "ensure_target_user_local_bin_on_path; "
            "ensure_target_user_local_bin_on_path",
            existing=set(),
            command_available_after=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.count("LOCAL_BIN_PATH_COUNT:1"), 2)

    def test_codex_installs_node_only_when_missing(self) -> None:
        result, trace = run_codex(existing=set(), codex_available_after=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(trace.index("INSTALL_NODE"), trace.index("CODEX_INSTALLER"))

    def test_codex_does_not_install_existing_node(self) -> None:
        result, trace = run_codex(existing={"node"}, codex_available_after=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("INSTALL_NODE", trace)

    def test_codex_confirms_installer_once(self) -> None:
        result, trace = run_codex(existing={"node"}, codex_available_after=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CODEX_INPUT:790a", trace)

    def test_codex_rejects_missing_command_after_installer(self) -> None:
        result, _ = run_codex(existing={"node"}, codex_available_after=False)
        self.assertNotEqual(result.returncode, 0)

    def test_codex_installer_failure_propagates(self) -> None:
        result, trace = run_codex(
            existing={"node"}, codex_available_after=True, installer_exit=42
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(trace.count("CHECK:codex"), 1)

    def test_codex_node_failure_through_task_stops_installer(self) -> None:
        result, trace = run_codex(
            existing=set(),
            codex_available_after=True,
            node_exit=42,
            through_run_task=True,
        )
        self.assertEqual(result.returncode, 42, result.stdout)
        self.assertIn("INSTALL_NODE", trace)
        self.assertNotIn("CODEX_INSTALLER", trace)

    def test_graph_skips_when_present(self) -> None:
        result, trace = run_graph(existing={"code-review-graph", "pipx"})
        self.assertEqual(result.returncode, TASK_SKIPPED)
        self.assertIn("LOCAL_BIN_PATH_COUNT:1", trace)
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

    def test_graph_apt_failure_through_task_stops_install(self) -> None:
        result, trace = run_graph(
            existing=set(),
            graph_available_after=True,
            apt_update_exit=42,
            through_run_task=True,
        )
        self.assertEqual(result.returncode, 42, result.stdout)
        self.assertIn("APT:update", trace)
        self.assertNotIn("APT:install -y pipx", trace)
        self.assertNotIn("TARGET:pipx install code-review-graph", trace)

    def test_graph_runs_user_local_pipx_under_sudo(self) -> None:
        result, trace = run_graph_with_user_local_pipx_under_sudo()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ["install code-review-graph"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
