# Installation Modules and Task UI Design

## Goal

Add independently selectable Codex and code-review-graph installation modules, organize the interactive selector into a collapsed two-level category tree, and replace verbose task output with concise execution status lines.

## Scope

- Keep `ubuntu_init.sh` as a single script with a flat canonical module execution order.
- Add `install_codex` and `install_code_review_graph` to `MODULE_ORDER`.
- Include both modules in `all`, argument-free non-interactive runs, and the interactive menu's default selection.
- Add category metadata only for the interactive menu. Category names do not become command-line arguments.
- Add one task runner for setup checks and installation/configuration modules.
- Update focused tests and README documentation.

## Module Categories

The interactive menu groups modules as follows while execution remains governed by `MODULE_ORDER`.

### Base tools

- `install_common_tools`
- `initialize_zsh`
- `set_default_editor`
- `configure_vim`

### Development tools

- `install_node`
- `install_codex`
- `install_code_review_graph`

### Docker

- `configure_docker`
- `install_docker`

### System configuration

- `configure_passwordless_sudo`
- `configure_journald`
- `configure_logrotate`
- `disable_apt_daily_timers`
- `disable_welcome_message`

## Interactive Menu

The menu initially shows all four categories collapsed, with every module selected.

- Up and Down move between visible rows.
- Right expands the focused category.
- Left collapses the focused category.
- Space on a category selects or clears every child module.
- Space on a module toggles only that module.
- Enter confirms the current selection from any row.
- The existing `Clear all selections` action remains at the top.
- An empty selection cannot be confirmed.

Category markers summarize child state:

- `[x]`: all children selected.
- `[-]`: some children selected.
- `[ ]`: no children selected.

Expanded modules are indented below their category. Categories and modules are menu presentation only; selected modules still execute once in canonical order.

## Codex Installation

`install_codex` runs for the target user.

1. Check for `codex` in the target user's environment. Load `$HOME/.nvm/nvm.sh` when present so NVM-installed commands are visible.
2. If Codex exists, return the task runner's skipped result.
3. Check for `node` in the same environment.
4. If Node.js is absent, call the existing `install_node` function before continuing.
5. Run the official installer exactly as a target-user shell pipeline:

   ```bash
   curl -fsSL https://chatgpt.com/codex/install.sh | sh
   ```

6. Check again for `codex` in the target-user environment and fail if it is unavailable.

The automatic Node.js prerequisite remains part of the Codex task and does not start a nested status spinner.

## code-review-graph Installation

`install_code_review_graph` also installs for the target user.

1. Check for `code-review-graph` in the target user's PATH and `$HOME/.local/bin`.
2. If found, return the task runner's skipped result.
3. If `pipx` is unavailable, run `apt update` and `apt install -y pipx` as root.
4. Run the following as the target user:

   ```bash
   pipx install code-review-graph
   ```

5. Verify the command in the target user's PATH or at `$HOME/.local/bin/code-review-graph`; fail if it is missing.

This avoids Ubuntu 24.04 system-Python package restrictions and keeps the package isolated.

## Task Status Runner

All setup checks and modules run through one status wrapper. Setup checks include operating-system validation, target-user resolution, and sudo validation.

In a TTY, the wrapper uses a single refreshing spinner line while a task runs and leaves one final line:

```text
✓ Installing Codex
- Installing Codex (skipped)
✗ Installing Codex
```

In a non-TTY environment, it emits stable plain-text lines without ANSI control sequences:

```text
START Installing Codex
OK Installing Codex
SKIPPED Installing Codex
FAILED Installing Codex
```

Each task writes stdout and stderr to its own temporary log. Successful and skipped task logs are discarded. On failure, the wrapper prints the captured log, removes the temporary file, and returns the task's original nonzero status. Signal handling restores terminal state and removes temporary files on `INT`, `TERM`, and `HUP`.

The implementation will define one internal skipped-result convention distinct from success and ordinary failure. The wrapper translates it into `SKIPPED`; it must not terminate the overall run.

## Error Handling

- Existing `set -euo pipefail` semantics remain in force.
- A failed installer pipeline fails its module.
- Missing commands after an apparently successful installer fail their module.
- Dependency installation errors propagate through the parent task.
- Failure is fail-fast: later modules do not run after a failed task.
- Captured failure output is shown so reduced normal output does not reduce diagnosability.

## Tests

Focused tests will verify:

- Both modules appear in canonical order, module listing/help output, and README.
- Codex skips when present, avoids reinstalling existing Node.js, installs Node.js when absent, propagates installer failure, and rejects a missing post-install command.
- code-review-graph skips when present, installs missing `pipx` with APT, invokes `pipx install code-review-graph` as the target user, propagates failure, and rejects a missing post-install command.
- The menu starts collapsed and selected, expands and collapses categories, toggles complete categories and individual modules, displays partial selection, preserves clear-all behavior, and rejects empty selection.
- The task runner handles success, skip, and failure; hides successful logs; prints failure logs; and emits no spinner/ANSI sequences outside a TTY.
- Existing smoke, Docker installation, and interactive menu behavior remains covered against regressions.

## Documentation

README will document:

- The two new modules.
- The four interactive categories.
- The two-level menu controls and collapsed initial state.
- Concise task status behavior and failure-log output.

No unrelated refactoring, new scripts, category command-line aliases, or optional configuration is included.
