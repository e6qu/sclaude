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
| 26 | `rm` without `-f` on temp Dockerfile can abort under `set -e` | Changed to `rm -f`; EXIT trap already handles cleanup |
| 27 | Helper container errors fully suppressed (`2>/dev/null \|\| true`) hides credential sync failures | Print explicit warning on stderr when helper container fails |
| 28 | T05 Linux test doesn't clean up fake `~/.claude/.credentials.json` on failure | Added trap-based cleanup in test subshell |
| 29 | T15 temp file race: other processes creating `/tmp/tmp.*` between before/after counts | Use a unique marker prefix instead of counting all tmp files |
| 30 | `docs/e2e-testing.md` embedded script stale: `((PASS++))` fails at zero with `set -e`, non-portable `stat -c`, missing timeout fallback | Removed embedded copy; docs now reference `test_e2e.sh` directly |
| 31 | `docs/storage-layout.md` credential sync only mentions macOS Keychain | Added Linux file-based sync paths |
| 32 | README uninstall: `docker rmi sclaude-sandbox` won't work (images tagged with hash) | Changed to `sclaude cleanup` then `docker rmi` |
| 33 | Runtime `sudo apt` support broken by `no-new-privileges` | Removed `no-new-privileges`, kept allowlisted sudo for `apt`/`apt-get`/`dpkg`, added the capabilities needed for package management, documented the tradeoff, and added an E2E package-install test |
| 34 | Management commands build the Docker image before dispatch | Dispatch wrapper commands before `ensure_image`; only build for actual CLI execution, `--build`, and `update` |
| 35 | Dockerfile GID handling still fragile when host GID exists in base image | Resolve existing groups by numeric GID with `getent`, create a group only when needed, and avoid assuming the group is named `agent` |
| 36 | `sclaude-apt` volume misleading and incomplete | Replaced it with shared `sagent-apt-cache` and `sagent-apt-lists` volumes used by the supported package-install path |
| 37 | Security docs overstate Docker bridge isolation | Updated docs to describe container localhost versus host gateway/alias reachability and outbound exfiltration risk |
| 38 | Credential-volume secret risk understated | Documented `sclaude-config` and `scodex-config` as secret-bearing volumes; Codex auth/config sync makes `scodex-config` sensitive |
| 39 | Wrapper flags parsed too late | Added wrapper parsing before dispatch while preserving native CLI args after the first non-wrapper argument |
| 40 | Codex CLI not supported | Added physical `scodex` script, one shared image with both CLIs, and tool-specific config/auth volumes |
| 41 | Claude and Codex flag semantics collide | Do not translate short flags; pass native args unchanged and document `scodex exec` for non-interactive Codex |
| 42 | Codex inner sandbox needs Docker-aware yolo mapping | `scodex` maps default yolo to `--dangerously-bypass-approvals-and-sandbox`; `--no-yolo` leaves native Codex behavior intact |
| 43 | Docker/devcontainer test commands can hang indefinitely when Docker becomes unresponsive | Added portable per-test timeouts and a bounded Docker readiness check to fail cleanly with captured output |
| 44 | Docker image builds hide useful progress because `docker build -q` only prints the final image ID | Removed quiet builds so `sclaude --build`, `scodex --build`, and `update` show full Docker build output |
| 45 | Scripts assume the `docker` command even when users run Podman directly | Added bounded container-engine detection with `SAGENT_CONTAINER_ENGINE=docker\|podman`, trying Docker first and Podman second when unset |
| 46 | Test timeouts killed only the top-level command and could leave child Docker/devcontainer processes running | Added recursive child-process termination to the E2E and devcontainer test harnesses |
| 47 | `test_devcontainers.sh` smoke phase can hang at `devcontainer up` against a Podman-backed Docker socket after the devcontainer image builds and the container starts | Recursive timeout cleanup fixed the stuck child process state; devcontainer suite now passes |

## False Positives

| Item | Reason |
|------|--------|
| `date` portability | `date -u +FORMAT` works on both BSD and GNU; flagged as fragility note only |
