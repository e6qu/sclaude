# Bug Tracker

## Open Bugs

None.

## Fixed Bugs

Numbering is stable: entries superseded by later fixes or made obsolete by
rewrites are pruned, leaving gaps. Tests and docs reference these numbers.

| # | Bug | Fix |
|---|-----|-----|
| 1 | Temp Dockerfile not cleaned up on build failure | `trap cleanup_temp EXIT` with `TEMP_FILES` array |
| 2 | Two extra containers spawned per run for `id -u`/`id -g` | Use host `$(id -u)` / `$(id -g)` directly |
| 3 | Volume permission fix only applied to config volume | Single container chowns all 4 user-writable volumes |
| 4 | Version hash doesn't include UID/GID | Added `USER_UID`/`USER_GID` to hash input |
| 6 | `-it` flags hardcoded without TTY check | `[ -t 0 ]` check: `-it` if terminal, `-i` otherwise |
| 7 | `/tmp` mounted with `noexec` breaks npm/pip tooling | Removed `noexec` from tmpfs flags |
| 8 | `ulimit nofile=1024` too restrictive for Node.js | Raised to 8192 |
| 10 | Workspace path with colons breaks Docker `-v` syntax | Validate and error early if `pwd` contains `:` |
| 11 | `reset` sends errors to stdout instead of stderr | Changed `2>&1` to `2>/dev/null` |
| 12 | Credential sync has no integrity check | JSON validation via `python3 -m json.tool` inside container |
| 13 | `shasum` not available on Linux | `portable_sha256()`: tries `sha256sum` first, falls back to `shasum` |
| 14 | No credential sync on Linux | Added `~/.claude/.credentials.json` and XDG config paths |
| 15 | `echo -e` not portable | Replaced with `printf` |
| 16 | No libsecret/D-Bus in container for Linux keyring | Added `libsecret-1-0 dbus dbus-x11 gnome-keyring` to Dockerfile |
| 17 | `BASH_SOURCE[0]` undefined in zsh | Changed to `${BASH_SOURCE[0]:-$0}` |
| 18 | `#!/bin/bash` shebang not portable | Changed to `#!/usr/bin/env bash` |
| 20 | `python3` used on HOST for credential validation (not guaranteed on Linux) | Moved JSON validation inside the container |
| 21 | `chown -R` on every run causes slow startup with populated volumes | Conditional: only recurse when ownership is wrong |
| 22 | Two extra containers per run (permissions + credentials) | Combined into a single helper container |
| 23 | `version` command spawns up to two containers for JSON formatting | Single container; format locally only if `python3` available |
| 24 | `timeout` not available on stock macOS (test file) | Portable fallback: `timeout` -> `gtimeout` -> none |
| 25 | `useradd` fails if host UID conflicts with existing container user | Added `-o` flag to allow duplicate UIDs |
| 27 | Helper container errors fully suppressed (`2>/dev/null \|\| true`) hides credential sync failures | Print explicit warning on stderr when helper container fails |
| 28 | T05 Linux test doesn't clean up fake `~/.claude/.credentials.json` on failure | Added trap-based cleanup in test subshell |
| 29 | T15 temp file race: other processes creating `/tmp/tmp.*` between before/after counts | Use a unique marker prefix instead of counting all tmp files |
| 33 | Runtime `sudo apt` support broken by `no-new-privileges` | Removed `no-new-privileges`, kept allowlisted sudo for `apt`/`apt-get`/`dpkg`, added the capabilities needed for package management, documented the tradeoff, and added an E2E package-install test |
| 34 | Management commands build the Docker image before dispatch | Dispatch wrapper commands before `ensure_image`; only build for actual CLI execution, `--build`, and `update` |
| 35 | Dockerfile GID handling still fragile when host GID exists in base image | Resolve existing groups by numeric GID with `getent`, create a group only when needed, and avoid assuming the group is named `agent` |
| 36 | `sclaude-apt` volume misleading and incomplete | Replaced it with shared `sagent-apt-cache` and `sagent-apt-lists` volumes used by the supported package-install path |
| 39 | Wrapper flags parsed too late | Added wrapper parsing before dispatch while preserving native CLI args after the first non-wrapper argument |
| 40 | Codex CLI not supported | Added physical `scodex` script, one shared image with both CLIs, and tool-specific config/auth volumes |
| 41 | Claude and Codex flag semantics collide | Do not translate short flags; pass native args unchanged and document `scodex exec` for non-interactive Codex |
| 42 | Codex inner sandbox needs Docker-aware yolo mapping | `scodex` maps default yolo to `--dangerously-bypass-approvals-and-sandbox`; `--no-yolo` leaves native Codex behavior intact |
| 43 | Docker/devcontainer test commands can hang indefinitely when Docker becomes unresponsive | Added portable per-test timeouts and a bounded Docker readiness check to fail cleanly with captured output |
| 44 | Docker image builds hide useful progress because `docker build -q` only prints the final image ID | Removed quiet builds so `sclaude --build`, `scodex --build`, and `update` show full Docker build output |
| 45 | Scripts assume the `docker` command even when users run Podman directly | Added bounded container-engine detection with `SAGENT_CONTAINER_ENGINE=docker\|podman`, trying Docker first and Podman second when unset |
| 46 | Test timeouts killed only the top-level command and could leave child Docker/devcontainer processes running | Added recursive child-process termination to the E2E and devcontainer test harnesses |
| 48 | `sclaude update` / `scodex update` rebuilds the image without updating the wrapper script itself, so a pre-`sagent-sandbox`-rename install keeps looping on "image not found" because its hash never matches a build that survives | `update` now self-updates both wrapper scripts from the latest release before rebuilding, re-execs with the new wrapper (guarded by `SAGENT_SKIP_SELF_UPDATE`), then verifies the image tag and prints the resulting CLI version |
| 49 | `--no-cache` rebuilds reuse the locally cached base image, so OS-level updates never land | `update` now passes `--pull` alongside `--no-cache` to refresh the base image |
| 50 | Docker build context was the wrapper's install directory, so every image build tarred and sent everything beside the script (all of `/usr/local/bin` for release installs — easily 100MB+ — or a repo checkout including `.git`) to the daemon | Build from an empty temp directory; the generated Dockerfile COPYs nothing so the context can be empty |
| 51 | `pip install` (even `--user`) fails inside the sandbox with PEP 668 `externally-managed-environment` on Ubuntu 24.04, making the dedicated `sagent-pip` volume unreachable via pip | Set `PIP_BREAK_SYSTEM_PACKAGES=1` in the image; added E2E test T18b |
| 52 | `update` self-update could clobber a source checkout: a symlinked `/usr/local/bin/sclaude` resolves into the git repo, and the downloaded release asset overwrites the working-tree file | Skip wrapper self-update when the resolved script lives in a git work tree; print `git pull` guidance and continue with the image rebuild |
| 53 | Release-tag fetch logic duplicated between `check_release` and `fetch_latest_release_tag` with divergent timeouts | `check_release` reuses `fetch_latest_release_tag` with an explicit 2s budget for the passive per-run check |
| 54 | Builds silently produce no usable image when Docker's default buildx builder uses the docker-container (or cloud) driver: the result stays in the build cache, then every run reports "image not found" and rebuilds again | Pass `--load` on docker builds so the result is exported to the image store (no-op for the default docker driver); podman needs no flag |
| 55 | T10 hides all failure output: `set -e` exits the test subshell when the captured `update` command fails, before the captured output is echoed, so a failing T10 reports `Output: (empty)` | Capture with `\|\| rc=$?` so the output is always echoed before the test exits |
| 56 | `sudo apt` broken for UID-1000 hosts (the common Linux desktop case): ubuntu:24.04 ships a default `ubuntu` user with UID 1000, sudo resolves the UID to that first passwd entry, and the `agent` NOPASSWD rule never applies (`sudo: a password is required`) | `userdel -r ubuntu` before creating `agent`; found by running the E2E suite inside the UID-1000 devcontainer — macOS (UID 501) and GitHub CI (UID 1001) never hit it |
| 57 | Host bind mounts unreadable on SELinux-enforcing hosts (Fedora/RHEL/CoreOS + podman): the Codex config sync's `~/.codex` mount fails with `Permission denied`, and the workspace mount would be equally unreadable at runtime | Codex config files now stream over stdin via tar (no bind mount, which also removed the colon-path limitation for `CODEX_HOME`); the workspace mount runs with `--security-opt label=disable` (a no-op for Docker and non-SELinux hosts) |
| 58 | A corrupted `~/.cache/sagent/release-check` file bricks every run: non-numeric content makes the interval arithmetic fail under `set -u` (`unbound variable`) before the CLI launches, until the file is manually deleted | Validate the cached timestamp is numeric, treating anything else as 0; added E2E test T25 |
| 59 | T10 silently tested released code instead of the code under test: after any release, every open branch's WRAPPER_VERSION is older than the latest tag, so the test's `update` self-updated its wrapper copy to the released asset and re-exec'd that | T10 pins `SAGENT_SKIP_SELF_UPDATE=1`; the self-update download path is instead verified against the real assets by the release workflow after each upload |
| 60 | Release workflow re-runs were not idempotent: `gh release upload` fails on existing assets and the install instructions get appended to the release body a second time; concurrent runs from quick merges could also race | `--clobber` on upload, a body-content guard before the notes edit, and a workflow-level concurrency group; a new step verifies published assets pass the self-updater's checks plus `bash -n` |
| 61 | E2E tests picked their image with `images \| head -1`, but the listing is not newest-first under podman's compat API — with multiple `sagent-sandbox` images present, tests could silently run against a stale image | Tests derive the image tag from the wrapper's own `version` output and verify it exists with `image inspect` |
| 62 | Runtime limits (`MEMORY_LIMIT`, `CPU_LIMIT`, `PIDS_LIMIT`) were baked into the image version hash even though they are container run flags, so tuning any of them forced a pointless full image rebuild | The hash now covers image content only (Dockerfile + UID/GID build args); limits are shown in `version` output instead |
| 63 | A config file with a bash syntax error aborted the wrapper mid-source with an error that never named the file | Validate with `bash -n` before sourcing and fail with a message naming the config file; covered by T28 |
| 64 | `reset` silently reported success while volumes survived: stale never-started/exited sandbox containers (e.g. `--rm` containers that failed to start) pin the volumes, and the `volume rm` failure was swallowed | `reset` first removes non-running sandbox-image containers, then removes volumes individually and fails loudly naming any volume still pinned by a running container; T09b covers the loud path |
| 65 | Running from a directory under `/tmp` gave the agent an empty workspace: the sandbox's tmpfs at `/tmp` shadows the workspace bind mount beneath it (mount ordering is engine-dependent; podman mounts the tmpfs last) | Omit the tmpfs when the workspace is `/tmp` or under it; T12b covers both the mount behavior and the wrapper path |
| 66 | Running from `/` bound the entire host filesystem over the container root — silently defeating the sandbox (the engine accepts `-v /:/`) | `validate_workspace` refuses `/` as the workspace with a clear error; T12c covers it |

## False Positives

| Item | Reason |
|------|--------|
| `date` portability | `date -u +FORMAT` works on both BSD and GNU; flagged as fragility note only |
