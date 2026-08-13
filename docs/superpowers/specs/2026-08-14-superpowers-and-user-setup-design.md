# Superpowers Installation and User Setup Design

## Goal

Extend `ubuntu_init.sh` with two independently selectable modules: install the
latest official Superpowers release for the target user, and interactively
create or configure a login user without disrupting unattended initialization.

## Superpowers module

Add `install_superpowers` to Development tools immediately after
`install_codex` in canonical execution order. At runtime it queries the tags of
`https://github.com/obra/superpowers.git`, considers only semantic-version tags
of the form `vMAJOR.MINOR.PATCH`, version-sorts them, and selects the newest.

The repository lives at `$TARGET_HOME/.codex/superpowers`. On first install the
module performs a shallow clone of the selected tag. If the path already holds
the official Git repository, the module fetches tags and checks out the newest
release in detached-HEAD state. If the path exists but is not that repository,
the module fails without altering it.

The module creates `$TARGET_HOME/.agents/skills` and the symbolic link
`$TARGET_HOME/.agents/skills/superpowers`, whose target is
`$TARGET_HOME/.codex/superpowers/skills`. An existing correct link is accepted.
An incorrect link, regular file, or directory causes a safe failure. Repository
operations and link creation run as the target user. Completion requires both
an exact checkout of the selected tag and a link resolving to the skills
directory.

## User setup module

Add `create_user` to System configuration after Docker installation in
canonical execution order. It is an explicit-only module: selecting it by name
or through the interactive menu runs it, while `all` and an argument-free run
without a controlling terminal omit it. This preserves unattended behavior.

The module reads from `/dev/tty`. If no controlling terminal is available, it
returns the existing skipped-task status. It prompts first for a username;
empty input skips the task. Valid usernames begin with a lowercase letter and
then contain only lowercase letters, digits, `_`, or `-`. Invalid input is
explained and requested again.

It then prompts for one optional, single-line OpenSSH public key. Empty input
continues without configuring a key. Accepted key types are `ssh-ed25519`,
`ssh-rsa`, and `ecdsa-sha2-*`, followed by non-whitespace key data and an
optional comment. Invalid input is explained and requested again.

For a missing account, the module runs
`adduser --disabled-password --gecos "" USERNAME`. An existing account is
reused. It always ensures membership in `sudo`. It adds membership in `docker`
only when that group exists; a missing Docker group produces an informational
message rather than failure.

When a key is supplied, the module obtains the account home and primary group
from the system account database, creates `.ssh` with mode `0700`, and creates
or appends to `authorized_keys` without overwriting existing keys or adding a
duplicate. It sets `authorized_keys` to `0600` and assigns both paths to the
account and its primary group. It does not recursively change the home
directory.

Passwordless sudo remains solely the responsibility of the existing
`configure_passwordless_sudo` module.

## Menu and command behavior

Both modules appear in `--list`, `--help`, their assigned interactive menu
categories, and README module documentation. Interactive menu defaults continue
to select ordinary modules, including `install_superpowers`, but do not select
`create_user` by default. Users may explicitly toggle `create_user` in the
expanded System configuration category.

When `all` is combined with explicit module names, the ordinary modules run as
usual and `create_user` runs only if it was named explicitly. All selected
modules retain canonical execution order.

## Error handling

Network, Git, account creation, group modification, filesystem, ownership, and
permission failures propagate through the existing task runner. Conflict
checks happen before destructive operations. User input validation loops only
for invalid interactive values; an empty username or unavailable terminal is a
normal skip.

## Testing

Automated tests cover Superpowers first installation, upgrade, idempotence,
repository conflict, link conflict, and verification failure. User tests cover
empty username, unavailable terminal, validation retries, new and existing
accounts, optional and duplicate keys, permissions and ownership commands, and
missing Docker group behavior.

Menu tests verify category membership, default selection, explicit selection,
`all` exclusion, and canonical ordering. Final verification runs the complete
Python unit-test suite, `tests/smoke.sh`, and `bash -n ubuntu_init.sh`.
