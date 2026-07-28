#!/usr/bin/env python3

import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT_DIR / "ubuntu_init.sh"


def script_definitions() -> str:
    script_text = SCRIPT_PATH.read_text()
    definitions, separator, trailer = script_text.rpartition('\nmain "$@"')
    if not separator or trailer.strip():
        raise AssertionError('ubuntu_init.sh must end with main "$@"')
    return definitions


def run_install_docker(
    installer_exit: int = 0,
    docker_available_after_installer: bool = False,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    with tempfile.TemporaryDirectory() as temporary_directory:
        directory = Path(temporary_directory)
        driver = directory / "docker_driver.sh"
        trace_file = directory / "trace"
        check_file = directory / "docker_checks"
        check_file.write_text("0\n")
        trace_path = shlex.quote(str(trace_file))
        check_path = shlex.quote(str(check_file))
        driver.write_text(
            script_definitions()
            + f"""
TRACE_FILE={trace_path}
DOCKER_CHECK_FILE={check_path}
INSTALLER_EXIT={installer_exit}
DOCKER_AVAILABLE_AFTER_INSTALLER={int(docker_available_after_installer)}

is_root() {{ return 0; }}

command() {{
  if [ "$1" = "-v" ] && [ "${{2:-}}" = "docker" ]; then
    checks="$(cat "$DOCKER_CHECK_FILE")"
    checks=$((checks + 1))
    printf '%s\n' "$checks" >"$DOCKER_CHECK_FILE"
    if [ "$DOCKER_AVAILABLE_AFTER_INSTALLER" -eq 1 ] && [ "$checks" -ge 2 ]; then
      return 0
    fi
    return 1
  fi
  builtin command "$@"
}}

wget() {{
  printf '#!/usr/bin/env bash\nexit %s\n' "$INSTALLER_EXIT"
}}

run_as_root() {{
  printf '%s\n' "$*" >>"$TRACE_FILE"
  case "$1" in
    bash) "$@" ;;
    mkdir|systemctl) return 0 ;;
    *) return 99 ;;
  esac
}}

install_docker
"""
        )
        result = subprocess.run(
            ["/bin/bash", str(driver)],
            capture_output=True,
            text=True,
        )
        trace = trace_file.read_text().splitlines() if trace_file.exists() else []
    return result, trace


class DockerInstallTest(unittest.TestCase):
    def test_creates_apt_sources_directory_before_installer(self) -> None:
        result, trace = run_install_docker(docker_available_after_installer=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            trace[:2],
            ["mkdir -p /etc/apt/sources.list.d", "bash"],
        )

    def test_missing_docker_after_successful_installer_fails_before_systemctl(self) -> None:
        result, trace = run_install_docker()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("systemctl enable docker", trace)
        self.assertNotIn("systemctl restart docker", trace)

    def test_installer_failure_propagates_before_systemctl(self) -> None:
        result, trace = run_install_docker(installer_exit=42)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn("systemctl enable docker", trace)
        self.assertNotIn("systemctl restart docker", trace)

    def test_successful_install_enables_and_restarts_docker(self) -> None:
        result, trace = run_install_docker(docker_available_after_installer=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            trace,
            [
                "mkdir -p /etc/apt/sources.list.d",
                "bash",
                "systemctl enable docker",
                "systemctl restart docker",
            ],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
