# Bug Tracker

## Open Bugs

None.

## Fixed Bugs

| # | Bug | Fix |
|---|-----|-----|
| 1 | Temp Dockerfile not cleaned up on build failure | `trap cleanup_temp EXIT` with `TEMP_FILES` array |
| 2 | Two extra containers spawned per run for `id -u`/`id -g` | Use host `$(id -u)` / `$(id -g)` directly |
| 3 | Volume permission fix only applied to config volume | Single container chowns all 4 user-writable volumes |
| 4 | Version hash doesn't include UID/GID | Added `USER_UID`/`USER_GID` to hash input |
| 5 | Fragile Dockerfile user/group creation | `groupadd -f` + `useradd -o -g claude` |
| 6 | `-it` flags hardcoded without TTY check | `[ -t 0 ]` check: `-it` if terminal, `-i` otherwise |
| 7 | `/tmp` mounted with `noexec` breaks npm/pip tooling | Removed `noexec` from tmpfs flags |
| 8 | `ulimit nofile=1024` too restrictive for Node.js | Raised to 8192 |
| 9 | Misleading "Script changed" rebuild message | Changed to "Image not found (version: ...), building..." |
| 10 | Workspace path with colons breaks Docker `-v` syntax | Validate and error early if `pwd` contains `:` |
| 11 | `reset` sends errors to stdout instead of stderr | Changed `2>&1` to `2>/dev/null` |
| 12 | Credential sync has no integrity check | JSON validation via `python3 -m json.tool` inside container |
| 13 | `shasum` not available on Linux | `portable_sha256()`: tries `sha256sum` first, falls back to `shasum` |
| 14 | No credential sync on Linux | Added `~/.claude/.credentials.json` and XDG config paths |
| 15 | `echo -e` not portable | Replaced with `printf` |
| 16 | No libsecret/D-Bus in container for Linux keyring | Added `libsecret-1-0 dbus dbus-x11 gnome-keyring` to Dockerfile |
| 17 | `BASH_SOURCE[0]` undefined in zsh | Changed to `${BASH_SOURCE[0]:-$0}` |
| 18 | `#!/bin/bash` shebang not portable | Changed to `#!/usr/bin/env bash` |
| 19 | No shell/platform compatibility documentation | Added supported shells/platforms to script header |
| 20 | `python3` used on HOST for credential validation (not guaranteed on Linux) | Moved JSON validation inside the container |
| 21 | `chown -R` on every run causes slow startup with populated volumes | Conditional: only recurse when ownership is wrong |
| 22 | Two extra containers per run (permissions + credentials) | Combined into a single helper container |
| 23 | `version` command spawns up to two containers for JSON formatting | Single container; format locally only if `python3` available |
| 24 | `timeout` not available on stock macOS (test file) | Portable fallback: `timeout` -> `gtimeout` -> none |
| 25 | `useradd` fails if host UID conflicts with existing container user | Added `-o` flag to allow duplicate UIDs |

## False Positives

| Item | Reason |
|------|--------|
| `date` portability | `date -u +FORMAT` works on both BSD and GNU; flagged as fragility note only |
