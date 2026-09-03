# E2E Testing

A single cross-platform test suite (`test_e2e.sh`) that runs on macOS and
Linux, against Docker or Podman.

## Prerequisites

- Docker or Podman installed and running
- bash (for running the test script)
- zsh (for zsh compatibility tests; skipped gracefully if absent)

## Test Matrix

| Test | What it validates | Bugs covered |
|---|---|---|
| T01: `version` command | Basic execution, hashing (`shasum` vs `sha256sum`) | #13 |
| T02: Image build | Dockerfile generation, UID/GID mapping | #1, #4, #35 |
| T03: Piped input (no TTY) | Non-TTY detection, `-it` flag handling | #6 |
| T04: `--yolo` flag conversion | Flag rewriting | -- |
| T05: Credential sync | macOS Keychain / Linux file-based creds | #12, #14, #16 |
| T06: Volume creation & permissions | Shared user volumes writable by agent user | #3 |
| T07: Volume persistence | Data survives across container runs | -- |
| T08: Cleanup command | Old image removal | -- |
| T09: Reset command | Volume deletion (non-interactive) | #11 |
| T10: Update command | `--no-cache` rebuild | -- |
| T11: Resource limits (PID) | Fork bomb containment | -- |
| T12: Path with spaces | Quoting correctness in mounts | #10 |
| T13: `echo -e` / printf portability | No literal `-e` in output | #15 |
| T14: Zsh invocation | `BASH_SOURCE` fallback | #17 |
| T15: Temp file cleanup on failure | No leaked temp files after failed build | #1 |
| T16: Shebang portability | Script runs via `env bash` | #18 |
| T17: scodex version command | Codex wrapper smoke test | #40 |
| T17b: scodex exec --help | Inner Codex CLI loads config without errors | -- |
| T17c: sclaude --help | Inner Claude CLI loads config without errors | -- |
| T18: sudo apt works in sandbox | Package installation support | #33, #36 |
| T18b: pip install --user works | PEP 668 override lands packages in `sagent-pip` | #51 |
| T19: Shared image has both CLIs | One image contains Claude and Codex CLIs | #40 |
| T20: scodex config sync | Codex `auth.json` and `config.toml` sync to `scodex-config` | #40 |
| T21: Release check non-fatal | Wrapper update check caches and does not fail normal flow | -- |
| T22: Native args pass through | Tool args after native command are not wrapper-dispatched | #39, #41 |
| T23: Explicit engine selection | `SAGENT_CONTAINER_ENGINE` works for both wrappers | -- |
| T24: Wrapper parity | Shared functions identical between `sclaude` and `scodex` (drift guard) | -- |
| T25: Corrupted release cache | Non-numeric cache content does not break execution | #58 |
| T26: `--force-rebuild` validation | Flag rejected outside the `update` command | -- |
| T04b: `--docker` flags | `--docker`/`--no-docker`/`SAGENT_DOCKER` parse | -- |
| T27: Nested containers | `--docker` mode: nested pull/run/build via rootless podman | -- |
| T28: Config file | Config sourced at startup; env vars take precedence | -- |
| T29: Browser-open shim | `xdg-open`/`$BROWSER` render clickable terminal hyperlinks | -- |

Bug numbers in the matrix refer to entries in [`BUGS.md`](../BUGS.md).

## Running the Tests

**The suite is destructive to sandbox state on the selected engine**: T09
deletes all `sclaude-`/`scodex-`/`sagent-` volumes (persisted credentials,
packages, sessions) and T10 force-rebuilds the shared image. Credentials
re-sync automatically on the next run, but shell history, preferences, and
installed packages in the sandbox are lost.

From the repo root on macOS or Linux:

```bash
bash test_e2e.sh                                # against Docker (default)
SAGENT_CONTAINER_ENGINE=podman bash test_e2e.sh # against Podman
```

Each test has a portable timeout so engine hangs fail cleanly instead of
blocking the suite. Override with `TEST_TIMEOUT_SECONDS=1200` when testing on
a slow builder.

### Testing Linux from a macOS host

Any Linux VM with a container engine works. Two options that need no extra
setup beyond their own tooling:

```bash
# Rootless Podman inside the Podman machine VM (SELinux-enforcing Fedora CoreOS)
podman machine ssh --username core podman-machine-default \
    'SAGENT_CONTAINER_ENGINE=podman bash /path/to/sclaude/test_e2e.sh'

# Docker inside this repo's docker-in-docker devcontainer (UID-1000 Ubuntu)
npm install -g @devcontainers/cli
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash /workspaces/sclaude/test_e2e.sh
```

These two configurations exercise real platform differences: SELinux label
enforcement (bug #57) and the UID-1000 sudoers collision (bug #56).

### CI (GitHub Actions)

For pushes to main and same-repo PRs, CI runs the suite on Linux
(`ubuntu-latest`) against Docker and against Podman, and again inside the
UID-1000 docker-in-docker dev container; see
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml). macOS runs are done
locally (GitHub's macOS runners cannot run Docker).
