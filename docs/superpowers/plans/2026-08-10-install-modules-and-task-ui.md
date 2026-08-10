# Installation Modules and Task UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add idempotent Codex and code-review-graph installation modules, a collapsed categorized selector, and concise task status output to the Ubuntu initializer.

**Architecture:** Keep the script's flat `MODULE_ORDER` execution model. Add installation functions and category metadata inside `ubuntu_init.sh`; isolate output/status behavior behind one `run_task` wrapper so module functions remain directly testable. Extend the existing Python PTY tests and shell smoke suite, with focused Python harnesses for installers and status behavior.

**Tech Stack:** Bash 4+, Python 3 `unittest`, PTY-based terminal tests, Ubuntu APT, NVM, pipx.

## Global Constraints

- Ubuntu support remains `>= 24.04`.
- Code comments and commit messages must be English.
- `install_codex` and `install_code_review_graph` are independent modules included by `all` and selected by default.
- Codex installation must execute `curl -fsSL https://chatgpt.com/codex/install.sh | sh` as the target user.
- A missing Node.js prerequisite must be satisfied through the existing `install_node` function.
- code-review-graph must be installed with `pipx install code-review-graph` as the target user; missing pipx must be installed with APT.
- Existing command-line module names remain the only selectable command-line units; category aliases are out of scope.
- The menu starts with all categories collapsed and all modules selected.
- Successful task logs stay hidden; failed task logs are printed.
- Avoid unrelated refactoring and preserve canonical module execution order.

## File Map

- Modify `ubuntu_init.sh`: skipped-result convention, task runner, two installers, category metadata, hierarchical selector, and status-wrapped setup/module execution.
- Create `tests/task_status_test.py`: direct non-TTY status-runner behavior and captured-log assertions.
- Create `tests/developer_tools_install_test.py`: isolated installer harnesses for Codex and code-review-graph.
- Modify `tests/interactive_menu_test.py`: categorized PTY navigation and canonical execution assertions.
- Modify `tests/smoke.sh`: static integration checks and execution of new focused tests.
- Modify `README.md`: categorized menu, status output, and module documentation.

---

### Task 1: Concise Task Status Runner

**Files:**
- Create: `tests/task_status_test.py`
- Modify: `ubuntu_init.sh` near `log_step`, cleanup globals, `run_module`, and `main`

**Interfaces:**
- Produces: `readonly TASK_SKIPPED=20`, variadic `run_task DESCRIPTION COMMAND_AND_ARGUMENTS`, `cleanup_task_status`, and `run_module MODULE`.
- `run_task` returns `0` for success, `0` after rendering an internal `TASK_SKIPPED`, and the original status for ordinary failure.
- `run_task` captures command output per invocation and selects TTY or plain rendering with `[ -t 1 ]`.

- [ ] **Step 1: Write focused non-TTY tests**

Create `tests/task_status_test.py`. Load script definitions by splitting before the final `main "$@"`, then run small Bash drivers. Include these exact cases:

```python
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
```

Define `TASK_SKIPPED = 20` in the Python test to assert the documented protocol. Capture combined stdout/stderr so failure logs can be asserted without depending on stream ordering.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
python3 -m unittest -v tests/task_status_test.py
```

Expected: FAIL because `TASK_SKIPPED`, `cleanup_task_status`, and `run_task` do not exist.

- [ ] **Step 3: Implement the minimal task runner**

In `ubuntu_init.sh`:

- Add `readonly TASK_SKIPPED=20`, `TASK_LOG_FILE=""`, and `TASK_SPINNER_PID=""` near existing globals.
- Add `cleanup_task_status` that kills/waits for a live spinner, restores the cursor only when stdout is a TTY, removes `TASK_LOG_FILE`, and clears both globals.
- Add a small `render_spinner DESCRIPTION` loop using frames `| / - \\`, updating one line with `\r` and sleeping `0.1` seconds.
- Implement `run_task` with this control flow:

```bash
run_task() {
  local description="$1"
  local status
  shift
  TASK_LOG_FILE="$(mktemp)"

  if [ -t 1 ]; then
    printf '\033[?25l'
    render_spinner "$description" &
    TASK_SPINNER_PID=$!
  else
    printf 'START %s\n' "$description"
  fi

  set +e
  "$@" >"$TASK_LOG_FILE" 2>&1
  status=$?
  set -e

  if [ -n "$TASK_SPINNER_PID" ]; then
    kill "$TASK_SPINNER_PID" 2>/dev/null || true
    wait "$TASK_SPINNER_PID" 2>/dev/null || true
    TASK_SPINNER_PID=""
  fi

  if [ "$status" -eq 0 ]; then
    [ -t 1 ] && printf '\r\033[2K✓ %s\n' "$description" || printf 'OK %s\n' "$description"
    cleanup_task_status
    return 0
  fi

  if [ "$status" -eq "$TASK_SKIPPED" ]; then
    [ -t 1 ] && printf '\r\033[2K- %s (skipped)\n' "$description" || printf 'SKIPPED %s\n' "$description"
    cleanup_task_status
    return 0
  fi

  [ -t 1 ] && printf '\r\033[2K✗ %s\n' "$description" || printf 'FAILED %s\n' "$description"
  cat "$TASK_LOG_FILE"
  cleanup_task_status
  return "$status"
}
```

In TTY mode use `✓`, `- (skipped)`, and `✗`; in plain mode use `OK`, `SKIPPED`, and `FAILED`. Ordinary failure must preserve the captured status. Success and skip clean up and return `0`.

Update signal traps used by the menu so they call both `cleanup_interactive_menu` and `cleanup_task_status`. Wrap setup calls in `main`:

```bash
run_task "Checking operating system" require_supported_os
run_task "Resolving target user" init_target_user
run_task "Checking sudo privileges" require_sudo
```

Change `run_module` to call `run_task "$(module_description "$module")" "$module"` and remove its standalone `log_step` call.

- [ ] **Step 4: Run focused and existing tests**

Run:

```bash
python3 -m unittest -v tests/task_status_test.py
bash tests/smoke.sh
```

Expected: task status tests PASS. Existing smoke tests may require the harness adjustment reserved for Task 4, but no production assertion unrelated to output capture may fail.

- [ ] **Step 5: Commit the status runner**

```bash
git add ubuntu_init.sh tests/task_status_test.py
git commit -m "feat: add concise task status output"
```

---

### Task 2: Developer Tool Installation Modules

**Files:**
- Create: `tests/developer_tools_install_test.py`
- Modify: `ubuntu_init.sh` after `install_node`, in `MODULE_ORDER`, and in `module_description`

**Interfaces:**
- Consumes: `run_as_root`, `run_as_target_user`, `install_node`, `die`, and `TASK_SKIPPED`.
- Produces: `target_user_has_command NAME`, `install_codex`, and `install_code_review_graph`.
- `target_user_has_command` must load `$HOME/.nvm/nvm.sh` when present and prepend `$HOME/.local/bin` to PATH before `command -v`.

- [ ] **Step 1: Write isolated installer tests**

Create a Python `unittest` harness following `tests/docker_install_test.py`: extract script definitions, append Bash overrides, invoke one installer, and record mocked calls in a trace file. Add cases asserting:

```python
def test_codex_skips_when_present(self):
    result, trace = run_codex(existing={"codex", "node"})
    self.assertEqual(result.returncode, TASK_SKIPPED)
    self.assertNotIn("INSTALL_NODE", trace)
    self.assertNotIn("CODEX_INSTALLER", trace)

def test_codex_installs_node_only_when_missing(self):
    result, trace = run_codex(existing=set(), codex_available_after=True)
    self.assertEqual(result.returncode, 0)
    self.assertLess(trace.index("INSTALL_NODE"), trace.index("CODEX_INSTALLER"))

def test_codex_does_not_install_existing_node(self):
    result, trace = run_codex(existing={"node"}, codex_available_after=True)
    self.assertEqual(result.returncode, 0)
    self.assertNotIn("INSTALL_NODE", trace)

def test_codex_rejects_missing_command_after_installer(self):
    result, _ = run_codex(existing={"node"}, codex_available_after=False)
    self.assertNotEqual(result.returncode, 0)

def test_graph_skips_when_present(self):
    result, trace = run_graph(existing={"code-review-graph", "pipx"})
    self.assertEqual(result.returncode, TASK_SKIPPED)
    self.assertNotIn("APT", trace)
    self.assertNotIn("PIPX_INSTALL", trace)

def test_graph_installs_missing_pipx_then_package_as_target_user(self):
    result, trace = run_graph(existing=set(), graph_available_after=True)
    self.assertEqual(result.returncode, 0)
    self.assertIn("APT:update", trace)
    self.assertIn("APT:install -y pipx", trace)
    self.assertIn("TARGET:pipx install code-review-graph", trace)

def test_graph_rejects_missing_command_after_install(self):
    result, _ = run_graph(existing={"pipx"}, graph_available_after=False)
    self.assertNotEqual(result.returncode, 0)
```

Also add separate cases in which the mocked Codex installer or pipx command returns `42`; assert `42` propagates and post-install verification does not conceal it.

- [ ] **Step 2: Run installer tests and verify failure**

Run:

```bash
python3 -m unittest -v tests/developer_tools_install_test.py
```

Expected: FAIL because the new installer functions are undefined.

- [ ] **Step 3: Implement target-user command detection and installers**

Add this behavioral shape without introducing a general dependency framework:

```bash
target_user_has_command() {
  local command_name="$1"
  run_as_target_user bash -c '
    export PATH="$HOME/.local/bin:$PATH"
    export NVM_DIR="$HOME/.nvm"
    [ ! -s "$NVM_DIR/nvm.sh" ] || . "$NVM_DIR/nvm.sh"
    command -v "$1" >/dev/null 2>&1
  ' bash "$command_name"
}

install_codex() {
  target_user_has_command codex && return "$TASK_SKIPPED"
  target_user_has_command node || install_node
  run_as_target_user bash -c '
    set -euo pipefail
    curl -fsSL https://chatgpt.com/codex/install.sh | sh
  '
  target_user_has_command codex ||
    die "Codex installation completed without installing the codex command."
}

install_code_review_graph() {
  target_user_has_command code-review-graph && return "$TASK_SKIPPED"
  if ! command -v pipx >/dev/null 2>&1; then
    run_as_root apt update
    run_as_root apt install -y pipx
  fi
  run_as_target_user pipx install code-review-graph
  target_user_has_command code-review-graph ||
    die "code-review-graph installation completed without installing the code-review-graph command."
}
```

When implementing, make the pipx availability check use the same target-user-aware helper rather than the root/current shell, while still using root only for APT. Ensure the harness can mock the installer pipeline without network access by overriding `curl`, `sh`, `run_as_target_user`, and command detection at function boundaries.

Insert canonical development order:

```bash
install_node
install_codex
install_code_review_graph
```

Add descriptions `Installing Codex` and `Installing code-review-graph`.

- [ ] **Step 4: Run focused tests**

Run:

```bash
python3 -m unittest -v tests/developer_tools_install_test.py tests/task_status_test.py
```

Expected: PASS.

- [ ] **Step 5: Commit the installer modules**

```bash
git add ubuntu_init.sh tests/developer_tools_install_test.py
git commit -m "feat: add developer tool installers"
```

---

### Task 3: Collapsed Two-Level Interactive Menu

**Files:**
- Modify: `ubuntu_init.sh` around module metadata and `select_modules_interactively`
- Modify: `tests/interactive_menu_test.py`

**Interfaces:**
- Consumes: `MODULE_ORDER` including both new modules.
- Produces: `CATEGORY_ORDER`, `category_description CATEGORY`, `category_modules CATEGORY`, and the revised `select_modules_interactively`.
- Category identifiers remain internal and are never accepted by `is_known_module`.

- [ ] **Step 1: Replace flat-menu tests with categorized navigation tests**

Update `MODULES` to include the two new modules after `install_node`. Define category fixtures with exact membership from the design. Add/assert these behaviors:

```python
def test_categories_start_collapsed_and_all_modules_selected(self):
    output, selected = self.run_menu(b"\r")
    self.assertEqual(selected, MODULES)
    self.assertIn("[x] Base tools", output)
    self.assertIn("[x] Development tools", output)
    self.assertNotIn("install_common_tools", first_render(output))

def test_right_expands_and_left_collapses_category(self):
    output, _ = self.run_menu(b"\x1b[C\x1b[D\r")
    self.assertIn("install_common_tools", output)
    self.assertGreaterEqual(output.count("Base tools"), 2)

def test_space_clears_an_entire_category(self):
    _, selected = self.run_menu(b" \r")
    self.assertEqual(selected, [m for m in MODULES if m not in BASE_TOOLS])

def test_child_toggle_gives_category_partial_marker(self):
    output, selected = self.run_menu(b"\x1b[C\x1b[B \r")
    self.assertNotIn("install_common_tools", selected)
    self.assertIn("[-] Base tools", output)

def test_categories_are_not_command_line_modules(self):
    result = subprocess.run(
        ["/bin/bash", str(SCRIPT_PATH), "docker"],
        capture_output=True,
        text=True,
    )
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("Unknown module: docker", result.stderr)
```

Preserve tests for clear-all, empty-selection rejection, help bypass, menu read failure, and canonical command-line ordering. Adapt key sequences to visible category/module rows. Update the main driver to append executed module names to a temporary trace file, because the task runner now captures module stdout.

- [ ] **Step 2: Run the PTY suite and verify failure**

Run:

```bash
python3 -m unittest -v tests/interactive_menu_test.py
```

Expected: FAIL because the menu is still flat and category metadata is absent.

- [ ] **Step 3: Add exact category metadata**

Add `CATEGORY_ORDER=(base_tools development_tools docker system_configuration)`. Implement `category_description` and `category_modules` as `case` statements returning the approved labels and space-delimited exact module names. Keep `MODULE_ORDER`, `is_known_module`, and `list_modules` flat.

- [ ] **Step 4: Implement visible-row navigation and tri-state selection**

Revise `select_modules_interactively` with these concrete state arrays:

```bash
local selected=()       # indexed by MODULE_ORDER
local expanded=(0 0 0 0) # indexed by CATEGORY_ORDER
local visible_types=()
local visible_values=()
```

At the start of each render, rebuild visible rows: append every category, followed by its child modules only when expanded. Implement small lookup loops that map module name to `MODULE_ORDER` index and compute each category's selected count. Render `[x]`, `[-]`, or `[ ]` from `selected_count` versus child count.

Navigation rules:

- `current=-1` remains the clear-all row.
- Up/Down wraps over clear-all plus `visible_values`.
- Right/Left only mutate `expanded` when the focused row type is `category`.
- Space on a category sets every child to `0` when all are selected, otherwise to `1`.
- Space on a module toggles its `selected` entry.
- Enter always builds `INTERACTIVE_SELECTED_MODULES` in `MODULE_ORDER`, rejects zero selection, and returns success otherwise.
- Recompute `menu_line_count` from the previous render's visible-row count so cursor-up redraw remains correct after expansion/collapse.

Do not create category command-line aliases or alter canonical execution.

- [ ] **Step 5: Run the menu and focused suites**

Run:

```bash
python3 -m unittest -v tests/interactive_menu_test.py tests/task_status_test.py tests/developer_tools_install_test.py
```

Expected: PASS.

- [ ] **Step 6: Commit the hierarchical menu**

```bash
git add ubuntu_init.sh tests/interactive_menu_test.py
git commit -m "feat: group modules in interactive menu"
```

---

### Task 4: Integration Coverage and Documentation

**Files:**
- Modify: `tests/smoke.sh`
- Modify: `README.md`
- Modify if required by verified regressions only: `ubuntu_init.sh`, `tests/interactive_menu_test.py`, `tests/task_status_test.py`, `tests/developer_tools_install_test.py`

**Interfaces:**
- Consumes all production interfaces from Tasks 1-3.
- Produces a documented and fully verified user-facing feature.

- [ ] **Step 1: Add smoke assertions before documentation changes**

Extend `tests/smoke.sh` with checks that grep or AWK the script for:

- `install_node`, then `install_codex`, then `install_code_review_graph` in canonical order.
- The exact `curl -fsSL https://chatgpt.com/codex/install.sh | sh` pipeline.
- `pipx install code-review-graph` and `apt install -y pipx`.
- Four category identifiers and descriptions.
- `run_task` wrapping all three setup checks and modules.

Add these commands to the final check list:

```bash
check "task status behavior" python3 "$ROOT_DIR/tests/task_status_test.py"
check "developer tool installers" python3 "$ROOT_DIR/tests/developer_tools_install_test.py"
```

Update the existing README checks to expect both new module rows.

- [ ] **Step 2: Run smoke tests and verify documentation assertions fail**

Run:

```bash
bash tests/smoke.sh
```

Expected: production checks PASS; new README checks FAIL until README is updated.

- [ ] **Step 3: Update README with the approved behavior**

Make surgical edits:

- Replace the flat-menu explanation with four category names, collapsed initial state, `Up/Down`, `Right/Left`, `Space`, and `Enter` controls.
- State that all modules remain selected initially and category grouping affects only the interactive selector.
- Add module rows:

```markdown
| `install_codex` | Install Codex CLI for the target user, installing Node.js first when required |
| `install_code_review_graph` | Install code-review-graph for the target user with pipx |
```

- Add a short `Task output` section explaining TTY spinner status, plain `START`/`OK`/`SKIPPED`/`FAILED` lines outside a TTY, hidden successful logs, and printed failure logs.

- [ ] **Step 4: Run the full verification suite**

Run:

```bash
bash -n ubuntu_init.sh
python3 -m unittest -v tests/task_status_test.py
python3 -m unittest -v tests/developer_tools_install_test.py
python3 -m unittest -v tests/interactive_menu_test.py
python3 -m unittest -v tests/docker_install_test.py
bash tests/smoke.sh
git diff --check
```

Expected: every command exits `0`; all tests report PASS; `git diff --check` emits no output.

- [ ] **Step 5: Review scope and commit**

Run:

```bash
git status --short
git diff --stat
git diff -- ubuntu_init.sh tests README.md
```

Confirm every changed line traces to installers, menu grouping, task status, tests, or documentation. Then commit:

```bash
git add ubuntu_init.sh tests/task_status_test.py tests/developer_tools_install_test.py tests/interactive_menu_test.py tests/smoke.sh README.md
git commit -m "docs: document developer install tasks"
```

## Final Acceptance Criteria

- `./ubuntu_init.sh --list` exposes both new modules without exposing categories as modules.
- Selecting only `install_codex` installs Node.js first only when the target user lacks it.
- Selecting only `install_code_review_graph` installs pipx with APT only when needed, then installs the package as the target user.
- Re-running either installed module yields `SKIPPED` and succeeds.
- The interactive menu starts with four collapsed, fully selected categories and implements the approved key behavior.
- TTY runs use one current-task status line; non-TTY runs use stable plain lines; only failed task logs are printed.
- All focused and regression tests pass on the final tree.
