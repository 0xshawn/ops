# Superpowers Installation and User Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe, testable modules for installing the newest Superpowers release and explicitly creating or configuring a user.

**Architecture:** Keep both features as shell functions in the existing single-file module framework. Isolate external effects behind existing `run_as_root` and `run_as_target_user` helpers, preserve canonical selection semantics, and exercise behavior with Bash test drivers from Python.

**Tech Stack:** Bash 4+, Python `unittest`, Git CLI, standard Ubuntu account tools

**Spec:** `docs/superpowers/specs/2026-08-14-superpowers-and-user-setup-design.md`

## Global Constraints

- Support Ubuntu 22.04 and newer.
- Code comments and commit messages must be English.
- `create_user` must never run through `all` or an argument-free noninteractive invocation.
- Existing files, directories, repositories, and SSH keys must not be overwritten.
- Passwordless sudo remains owned by `configure_passwordless_sudo`.

---

### Task 1: Superpowers installation module

**Files:**
- Modify: `ubuntu_init.sh` (developer-tool functions and module registry)
- Modify: `tests/developer_tools_install_test.py`

**Interfaces:**
- Consumes: `TARGET_HOME`, `run_as_target_user`, `die`, and `TASK_SKIPPED`
- Produces: `install_superpowers() -> shell status`, registered module name `install_superpowers`

- [ ] **Step 1: Add failing installer tests**

Add a temporary-home Bash driver that stubs `git` and records commands. Assert first install queries `ls-remote`, shallow-clones `v6.3.0`, and creates a link resolving to `.codex/superpowers/skills`. Also assert an official existing checkout is fetched and checked out, a correct link is accepted, and conflicting repository/link paths return nonzero without removal commands.

- [ ] **Step 2: Confirm the focused tests fail**

Run: `python3 -m unittest -v tests.developer_tools_install_test`

Expected: failures because `install_superpowers` and its registry entry do not exist.

- [ ] **Step 3: Write minimal release installation code**

Add `install_superpowers` that runs target-user Bash with strict mode. Use `git ls-remote --tags --refs`, extract tags with `awk`, filter `^v[0-9]+\.[0-9]+\.[0-9]+$`, then `sort -V | tail -n 1`. Fail when no tag exists. Clone a missing checkout with `--branch "$tag" --depth 1`; for an existing official checkout verify `remote.origin.url`, fetch the tag with depth one, and detach-checkout it. Validate conflicts before changes, create the parent and symlink, and verify `git describe --tags --exact-match` plus `readlink -f`.

- [ ] **Step 4: Register and verify the module**

Place it after `install_codex` in `MODULE_ORDER`, add it to Development tools, and describe it as `Installing Superpowers`.

Run: `python3 -m unittest -v tests.developer_tools_install_test`

Expected: PASS.

- [ ] **Step 5: Commit the module**

```bash
git add ubuntu_init.sh tests/developer_tools_install_test.py
git commit -m "feat: install latest Superpowers release"
```

### Task 2: Explicit interactive user setup module

**Files:**
- Modify: `ubuntu_init.sh` (user setup function, registry, and selection logic)
- Create: `tests/user_setup_test.py`
- Modify: `tests/interactive_menu_test.py`

**Interfaces:**
- Consumes: `has_controlling_terminal`, `run_as_root`, `log_step`, `die`, `TASK_SKIPPED`
- Produces: `create_user() -> shell status`, `is_default_module(module)`, registered module `create_user`

- [ ] **Step 1: Add failing user-effect tests**

Build a driver that replaces terminal reads with fixtures and records root commands. Cover invalid-then-valid username and key input, empty username skip, unavailable-terminal skip, new versus existing accounts, sudo membership, optional Docker membership, duplicate-key suppression, `mkdir -p HOME/.ssh`, modes `700` and `600`, and ownership `USER:GROUP`. Assert existing key content remains and a new key is appended once.

- [ ] **Step 2: Add failing selection tests**

Update menu constants and assertions so `create_user` belongs to System configuration but is absent from the initial selection. Assert `all` omits it, `create_user` alone runs it, and `all create_user` runs ordinary modules plus it in canonical order.

Run: `python3 -m unittest -v tests.user_setup_test tests.interactive_menu_test`

Expected: failures because the module and explicit-only rule are absent.

- [ ] **Step 3: Implement account configuration**

Add focused helpers for reading `/dev/tty`, validating username regex `^[a-z][a-z0-9_-]*$`, and validating key types `ssh-ed25519|ssh-rsa|ecdsa-sha2-[^[:space:]]+`. Implement with `getent passwd`, `getent group`, `adduser`, and `usermod -aG`. Resolve home and primary group after creation. Only create SSH paths when a key is supplied; append after an exact-line duplicate check.

- [ ] **Step 4: Implement explicit-only selection**

Register `create_user` after `install_docker` and in System configuration. Add `is_default_module`, false only for `create_user`. Use it for interactive initial selections and `run_all`. Preserve explicit names so `all create_user` includes it.

- [ ] **Step 5: Verify and commit user setup**

Run: `python3 -m unittest -v tests.user_setup_test tests.interactive_menu_test`

Expected: PASS.

```bash
git add ubuntu_init.sh tests/user_setup_test.py tests/interactive_menu_test.py
git commit -m "feat: add interactive user setup"
```

### Task 3: Documentation and full regression verification

**Files:**
- Modify: `README.md`
- Test: all files under `tests/`

**Interfaces:**
- Consumes: final module names and behavior from Tasks 1 and 2
- Produces: user-facing module and invocation documentation

- [ ] **Step 1: Update documentation**

Add both modules to the table. Document that `install_superpowers` tracks the newest official semantic release and that `create_user` must be selected explicitly, accepts an optional SSH key, safely reuses existing users, and is excluded from `all`.

- [ ] **Step 2: Run syntax and tests**

```bash
bash -n ubuntu_init.sh
python3 -m unittest discover -s tests -p '*_test.py' -v
bash tests/smoke.sh
```

Expected: all commands exit 0 with all tests passing.

- [ ] **Step 3: Review scope**

Run: `git diff --check && git status --short && git diff HEAD~2 -- README.md ubuntu_init.sh tests`

Expected: no whitespace errors and every changed line maps to the spec.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md
git commit -m "docs: describe setup modules"
```
