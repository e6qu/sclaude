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
| T06: Volume creation & permissions | Shared user volumes writable by agent user | #22 |
| T07: Volume persistence | Data survives across container runs | -- |
| T08: Cleanup command | Old image removal | -- |
| T09: Reset command | Volume deletion (non-interactive) | #64 |
| T10: Update command | `--no-cache` rebuild | -- |
| T11: Resource limits (PID) | Fork bomb containment | -- |
| T12: Path with spaces | Quoting correctness in mounts; the spaced path is actually mounted and read | #10, #73 |
| T09b: Reset pinned volumes | `reset` fails loudly naming volumes held by running containers | #64 |
| T12b: /tmp workspace | Workspace under /tmp not shadowed by the sandbox tmpfs; physical path mounted at the logical path; the agent can read and write it | #65, #71, #75 |
| T12c: / workspace refused | `/` as workspace rejected (would expose the host filesystem) | #66 |
| T13: `volumes` report | No literal `-e` in output; the disk usage report lists the image, every volume with a size, and the caches total | #15 |
| T14: Zsh invocation | `BASH_SOURCE` fallback | #17 |
| T15: Temp file cleanup on failure | No leaked temp files after failed build (searches `$TMPDIR`) | #1, #73 |
| T16: Shebang portability | Script runs via `env bash` | #18 |
| T17: scodex version command | Codex wrapper smoke test | #40 |
| T17b: scodex exec --help | Inner Codex CLI loads config without errors | -- |
| T17c: sclaude --help | Inner Claude CLI loads config without errors | -- |
| T18: sudo apt works in sandbox | Package installation support | #33, #36 |
| T18b: pip install --user works | PEP 668 override lands packages in `sagent-pip` | #51 |
| T19: Image contents | Claude, Codex and GitHub CLIs plus the configured Node, Python/pip/uv, Go, Rust (rustfmt, clippy), Java and podman/pasta at the versions the wrapper reports; every selected tool (TypeScript, tsx, bun, corepack with yarn/pnpm, create-next-app, create-vite, shadcn, Maven, Gradle, Quarkus CLI, Spring Boot CLI) present and every unselected one absent | #40 |
| T20: scodex config sync | Codex `auth.json` and `config.toml` sync to `scodex-config` | #40 |
| T21: Release check non-fatal | Wrapper update check caches and does not fail normal flow | -- |
| T22: Native args pass through | Tool args after native command are not wrapper-dispatched | #39, #41 |
| T23: Explicit engine selection | `SAGENT_CONTAINER_ENGINE` works for both wrappers | -- |
| T24: Wrapper parity | Shared functions and main dispatch identical between `sclaude` and `scodex` (drift guard) | -- |
| T25: Corrupted release cache | Non-numeric cache content does not break execution | #58 |
| T26: `--force-rebuild` validation | Flag rejected outside the `update` command | -- |
| T04b: `--docker` flags | `--docker`/`--no-docker`/`SAGENT_DOCKER` parse | -- |
| T27: Nested containers | `--docker` mode: nested pull/run/build via rootless podman | -- |
| T28: Config file | Config sourced at startup; env vars take precedence | -- |
| T29: Browser-open shim | `xdg-open`/`$BROWSER` render clickable terminal hyperlinks | -- |
| T30: Isolation assertions | No engine socket, no cross-tool secrets, no host-sibling leakage | -- |
| T31: `SAGENT_CA_BUNDLE` | Bundle validation, hash coverage, and a real build whose curl/Python/Node trust a certificate issued by a bundled CA | #68 |
| T32: Dockerfile generation | Stub engine: CA block emitted only with a bundle, one file per certificate in the context, build-failure guidance printed; FROM/ARG carry the toolchain versions, `none` omits a toolchain, `SAGENT_TOOLS` selects exactly the named tools | #68 |
| T33: VM share check | Stub engine reporting the `rancher-desktop` and `colima` contexts: a workspace outside `$HOME` is refused, `SAGENT_SKIP_SHARE_CHECK=1` and a `$HOME` workspace pass; other contexts are not checked | #74 |
| T34: docker CLI on rootless daemon | Stub engine reporting a rootless podman server: the run is refused before any engine call; `version` still works | #75 |
| T35: Toolchain settings | Invalid versions rejected up front; each setting changes the image hash; config file applies and the environment wins | -- |
| T36: Toolchain stamps | A pip volume stamped for another Python is cleared with a warning on the next run; an unchanged toolchain leaves it alone | #76 |
| T37: `reset-caches` | Cache volumes removed; credentials, config and home volumes kept | -- |
| T38: `tools` / `config` commands | Enable/disable rewrite `SAGENT_TOOLS` and change the hash; `config set/get/list/unset/path` with validation and unknown-key rejection; environment precedence reported; Java tools without a JDK | -- |
| T39: `status` | Every snapshot line present with the real engine and image; still prints, naming the problem, without an engine | -- |
| T40: `doctor` | Healthy setup: engine, workspace, image, CLIs, sandbox TLS, nested devices and cache stamps PASS, exit 0; missing engine and a rootless docker CLI stub produce FAIL lines and exit 1 | -- |

Bug numbers in the matrix refer to entries in [`BUGS.md`](../BUGS.md).

## Running the Tests

**The suite is destructive to sandbox state on the selected engine**: T09
and T37 delete `sclaude-`/`scodex-`/`sagent-` volumes (persisted credentials,
packages, sessions), T36 replaces the pip volume, T10 force-rebuilds the
shared image, and T31 builds a second image with a throwaway CA bundle
(removed afterwards). Credentials
re-sync automatically on the next run, but shell history, preferences, and
installed packages in the sandbox are lost.

From the repo root on macOS or Linux:

```bash
bash test_e2e.sh                                # against Docker (default)
SAGENT_CONTAINER_ENGINE=podman bash test_e2e.sh # against Podman
```

Test bodies run under `bash -ec`, so every command in a test is an assertion
(#72); guard commands that are allowed to fail with `|| true` or an `if`.

Fixtures that get bind-mounted into containers are created under
`SAGENT_TEST_TMPDIR` (default `/tmp`). Point it under your home directory for
engines that share only `$HOME` with their VM, such as Rancher Desktop. Tests
that replicate `run_tool`'s mounts pass `$SAGENT_TEST_USERNS`, which the
suite sets to the wrapper's keep-id mapping on rootless podman.

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

For pushes to main and same-repo PRs, CI runs the suite across the full
engine matrix (see [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)):

| Job | Topology |
|---|---|
| test-linux | docker CLI on docker server (Ubuntu, AppArmor enforcing) |
| test-linux-podman | rootless podman CLI on podman (exercises the keep-id user mapping, #75) |
| test-linux-docker-cli-podman | real docker CLI on a rootful podman docker-compat socket (a rootless socket is refused by the wrapper, see #75/T34) |
| test-linux-podman-shim | podman fronted as the `docker` command |
| test-macos | macOS host, docker CLI to dockerd in a colima Linux VM (Intel runner; Apple Silicon runners lack nested virtualization); skips T10 and T31, whose full image builds are engine-independent and covered by the Linux jobs, and T12b (colima shares only `$HOME` and `/tmp/colima`); builds a trimmed image (`SAGENT_TOOLS=none`, no Rust) via the config file so the cold build fits the job limit, which also exercises the "none" paths |
| test-macos-rancher | macOS host, Rancher Desktop's docker CLI (`~/.rd/bin`) to dockerd in its Lima VM, started headlessly with `rdctl`; skips T10, T31 and T12b (Rancher Desktop shares only `$HOME`, so a `/tmp` workspace cannot mount); same trimmed image as test-macos |
| test-devcontainers | UID-1000 docker-in-docker dev container |

T27 inside each job adds one more nesting level (nested podman in the
sandbox), so the devcontainer and macOS jobs exercise three to four layers of
container/VM nesting.
