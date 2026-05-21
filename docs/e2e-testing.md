# E2E Testing Plan for sclaude

A single cross-platform test suite that runs on both macOS and Linux, validating sclaude works correctly on each.

## Prerequisites

- Docker installed and running
- bash (for running the test script)
- zsh (for zsh compatibility tests; skip gracefully if absent)

### Additional: Testing Linux from a macOS host

To test Linux without a dedicated machine, use Lima to spin up a Linux VM:

```bash
brew install lima

# Create and start a Docker-enabled Ubuntu VM
limactl create --name=sclaude-linux --vm-type=vz --mount-writable template://docker
limactl start sclaude-linux

# Run the test suite inside the VM (home dir is auto-mounted)
lima sclaude-linux bash ~/projects/sclaude/test_e2e.sh
```

Optional Alpine VM (tests `/usr/bin/env bash` shebang portability):

```bash
limactl create --name=sclaude-alpine template://alpine
limactl start sclaude-alpine
lima sclaude-alpine apk add docker bash
lima sclaude-alpine rc-service docker start
lima sclaude-alpine bash ~/projects/sclaude/test_e2e.sh
```

## Test Matrix

| Test | What it validates | Bugs covered |
|---|---|---|
| T01: `version` command | Basic execution, hashing (`shasum` vs `sha256sum`) | #13 |
| T02: Image build | Dockerfile generation, UID/GID mapping | #1, #4, #5 |
| T03: Piped input (no TTY) | Non-TTY detection, `-it` flag handling | #6 |
| T04: `--yolo` flag conversion | Flag rewriting | -- |
| T05: Credential sync | macOS Keychain / Linux file-based creds | #12, #14, #17 |
| T06: Volume creation & permissions | Shared user volumes writable by agent user | #3 |
| T07: Volume persistence | Data survives across container runs | -- |
| T08: Cleanup command | Old image removal | -- |
| T09: Reset command | Volume deletion (non-interactive) | #11 |
| T10: Update command | `--no-cache` rebuild | -- |
| T11: Resource limits (PID) | Fork bomb containment | -- |
| T12: Path with spaces | Quoting correctness in mounts | #10 |
| T13: `echo -e` / printf portability | No literal `-e` in output | #15 |
| T14: Zsh invocation | `BASH_SOURCE` fallback | #18 |
| T15: Temp file cleanup on failure | No leaked temp files after failed build | #1 |
| T16: Shebang portability | Script runs via `env bash` | #19 |
| T17: scodex version command | Codex wrapper smoke test | #40 |
| T18: sudo apt works in sandbox | Package installation support | #33, #36 |
| T19: Shared image has both CLIs | One image contains Claude and Codex CLIs | #40 |
| T20: scodex config sync | Codex `auth.json` and `config.toml` sync to `scodex-config` | #38, #40 |
| T21: Release check non-fatal | Wrapper update check caches and does not fail normal flow | -- |
| T22: Native args pass through | Tool args after native command are not wrapper-dispatched | #39, #41 |
| T23: Explicit engine selection | `SAGENT_CONTAINER_ENGINE` works for both wrappers | -- |

## Test Script: `test_e2e.sh`

Single script, runs on macOS and Linux. Platform-specific tests are gated by OS detection.

See [`test_e2e.sh`](../test_e2e.sh) for the full source. The test matrix above documents what each test validates.

## Running the Tests

### On macOS (native)

```bash
cd ~/projects/sclaude
bash test_e2e.sh
```

Each test has a portable timeout so Docker or devcontainer hangs fail cleanly
instead of blocking the suite. Override with `TEST_TIMEOUT_SECONDS=1200` when
testing on a slow builder.

Run against native Podman instead of Docker-compatible Podman/Docker with:

```bash
SAGENT_CONTAINER_ENGINE=podman bash test_e2e.sh
```

### On Linux (native)

```bash
cd ~/projects/sclaude
bash test_e2e.sh
```

### On Linux via Lima VM (from macOS host)

```bash
# One-time setup
brew install lima
limactl create --name=sclaude-linux --vm-type=vz --mount-writable template://docker
limactl start sclaude-linux

# Run (home dir auto-mounted)
lima sclaude-linux bash ~/projects/sclaude/test_e2e.sh

# Cleanup VM when done
limactl stop sclaude-linux && limactl delete sclaude-linux
```

### CI (GitHub Actions)

```yaml
name: E2E Tests
on: [push, pull_request]

jobs:
  test-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Docker
        run: brew install --cask docker
      - name: Run E2E tests
        run: bash test_e2e.sh

  test-linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run E2E tests
        run: bash test_e2e.sh
```

## Bug Coverage Map

| Bug | Test | Notes |
|---|---|---|
| #1 Temp file leak | T15 | Checks /tmp before/after build |
| #3 Volume perms | T06 | Checks ownership of all 4 user volumes |
| #4 UID in hash | T06 | Ownership mismatch reveals stale image |
| #5 Group creation | T02 | Fails on Linux if GID 1000 is taken |
| #6 TTY check | T03 | Piped stdin |
| #10 Colons in path | T12 | Spaces tested; colons are filesystem-dependent |
| #11 Reset stderr | T09 | Checks volumes are actually removed |
| #12 Cred integrity | T05 | Checks creds land in volume |
| #13 shasum | T01 | Fails on Linux without fix |
| #14 Linux creds | T05 (Linux) | File-based sync path |
| #15 echo -e | T13 | Checks for literal "-e" |
| #17 D-Bus | T05 (Linux) | Credential storage in container |
| #18 BASH_SOURCE | T14 | zsh invocation |
| #19 Shebang | T16 | Checks first line of script |
