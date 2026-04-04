# Bug Tracker

## Outstanding Bugs

None.

## Fixed Bugs

All bugs below have been fixed and verified by the E2E test suite (`test_e2e.sh`).

### Round 1 (initial review)

| # | Bug | Fix |
|---|-----|-----|
| 1 | Temp Dockerfile not cleaned up on build failure | `trap cleanup_temp EXIT` with `TEMP_FILES` array |
| 2 | Two extra containers spawned per run for `id -u`/`id -g` | Use host `$(id -u)` / `$(id -g)` directly |
| 3 | Volume permission fix only applied to config volume | Single container chowns all 4 user-writable volumes |
| 4 | Version hash doesn't include UID/GID | Added `USER_UID`/`USER_GID` to hash input |
| 5 | Fragile Dockerfile user/group creation | `groupadd -f` (force) + `useradd -g claude` (always use claude group) |
| 6 | `-it` flags hardcoded without TTY check | `[ -t 0 ]` check: `-it` if terminal, `-i` otherwise |
| 7 | `/tmp` mounted with `noexec` breaks npm/pip tooling | Removed `noexec` from tmpfs flags |
| 8 | `ulimit nofile=1024` too restrictive for Node.js | Raised to 8192 |
| 9 | Misleading "Script changed" rebuild message | Changed to "Image not found (version: ...), building..." |
| 10 | Workspace path with colons breaks Docker `-v` syntax | Validate and error early if `pwd` contains `:` |
| 11 | `reset` sends errors to stdout instead of stderr | Changed `2>&1` to `2>/dev/null` |
| 12 | Credential sync has no integrity check | JSON validation via `python3 -m json.tool` inside container |
| 13 | `shasum` not available on Linux | `portable_sha256()`: tries `sha256sum` first, falls back to `shasum` |
| 14 | No credential sync on Linux | Added Linux path: `~/.claude/.credentials.json` and XDG config |
| 15 | `echo -e` not portable | Replaced with `printf` |
| 16 | `date` portability (fragility note) | Added comment documenting safe BSD/GNU usage |
| 17 | No libsecret/D-Bus in container for Linux keyring | Added `libsecret-1-0 dbus dbus-x11 gnome-keyring` to Dockerfile |
| 18 | `BASH_SOURCE[0]` undefined in zsh | Changed to `${BASH_SOURCE[0]:-$0}` |
| 19 | `#!/bin/bash` shebang not portable | Changed to `#!/usr/bin/env bash` |
| 20 | No shell/platform compatibility documentation | Added supported shells/platforms to script header |

### Round 2 (post-fix review)

| # | Bug | Fix |
|---|-----|-----|
| 21 | `python3` used on HOST for credential validation (not guaranteed on Linux) | Moved JSON validation inside the container where python3 is installed |
| 22 | `chown -R` on every run causes slow startup with populated volumes | Conditional: only recurse when ownership is actually wrong (`stat` check) |
| 23 | Two extra containers per run (permissions + credentials) | Combined into a single helper container |
| 24 | `version` command spawns up to two containers for JSON formatting | Single container; format locally only if `python3` available on host |
| 25 | `timeout` not available on stock macOS (test file) | Portable fallback: `timeout` -> `gtimeout` -> none |
| 26 | `useradd` fails if host UID conflicts with existing container user | Added `-o` flag to allow duplicate UIDs |

### Test harness bugs (found during E2E runs)

| Bug | Fix |
|-----|-----|
| `((PASS++))` returns exit 1 when PASS=0 under `set -e` | Changed to `PASS=$((PASS + 1))` |
| `grep -v` in cleanup pipeline fails when no old images exist | Wrapped in `{ grep -v ... \|\| true; }` |
| `stat`-based ownership check unreliable with Podman UID remapping | Changed T06 to test actual write access instead |

## False Positives

| Item | Why it's not a bug |
|------|-------------------|
| Bug 16 (`date` portability) | Current `date -u +FORMAT` usage works on both BSD and GNU. Documented as fragility note only. |
