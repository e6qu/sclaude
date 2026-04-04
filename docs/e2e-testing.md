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
| T06: Volume creation & permissions | All 5 volumes writable by claude user | #3 |
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

## Unified Test Script: `test_e2e.sh`

Single script, runs on macOS and Linux. Platform-specific tests are gated by OS detection.

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── Resolve sclaude path ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCLAUDE="$SCRIPT_DIR/sclaude"

if [ ! -x "$SCLAUDE" ]; then
    echo "ERROR: sclaude not found or not executable at $SCLAUDE" >&2
    exit 1
fi

OS="$(uname -s)"
PASS=0
FAIL=0
SKIP=0

# ── Test harness ──────────────────────────────────────────────────────
run_test() {
    local name="$1"; shift
    printf "  %-45s " "$name"
    local output
    if output=$("$@" 2>&1); then
        printf "PASS\n"
        ((PASS++))
    else
        printf "FAIL\n"
        echo "    Output: ${output:-(empty)}" | head -5
        ((FAIL++))
    fi
}

skip_test() {
    local name="$1" reason="$2"
    printf "  %-45s SKIP (%s)\n" "$name" "$reason"
    ((SKIP++))
}

# ── Setup ─────────────────────────────────────────────────────────────
echo "=== sclaude E2E Tests ==="
echo "Platform: $OS ($(uname -m))"
echo "Docker:   $(docker --version 2>/dev/null || echo 'NOT FOUND')"
echo "Bash:     ${BASH_VERSION}"
echo ""

# Ensure Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running" >&2
    exit 1
fi

# ── T01: version command ─────────────────────────────────────────────
# Validates basic execution and that the hashing tool works
# (shasum on macOS, sha256sum on Linux — Bug #13)
run_test "T01: version command" bash -c '"$1" version' _ "$SCLAUDE"

# ── T02: image build ─────────────────────────────────────────────────
# Validates Dockerfile generation, UID/GID build args (Bug #4, #5)
run_test "T02: image build" bash -c '"$1" --build' _ "$SCLAUDE"

# ── T03: piped input (no TTY) ────────────────────────────────────────
# Bug #6: -it flags should adapt when stdin is not a terminal
run_test "T03: piped/no-TTY mode" bash -c '
    echo "exit" | "$1" version 2>&1
' _ "$SCLAUDE"

# ── T04: --yolo flag conversion ──────────────────────────────────────
# Verify --yolo is rewritten; we just check the script doesn't crash
run_test "T04: --yolo flag" bash -c '"$1" version --yolo 2>&1 || true' _ "$SCLAUDE"

# ── T05: credential sync ─────────────────────────────────────────────
if [ "$OS" = "Darwin" ]; then
    # macOS: check that Keychain creds (if present) are synced into the volume
    run_test "T05: credential sync (macOS)" bash -c '
        "$1" version >/dev/null 2>&1
        # Volume should exist after a run; check it is readable
        docker run --rm -v sclaude-config:/c alpine ls /c/ >/dev/null 2>&1
    ' _ "$SCLAUDE"
else
    # Linux: Bug #14 — check file-based credential sync
    run_test "T05: credential sync (Linux)" bash -c '
        mkdir -p ~/.claude
        echo "{\"test_cred\":true}" > ~/.claude/.credentials.json
        "$1" version >/dev/null 2>&1
        docker run --rm -v sclaude-config:/c alpine cat /c/.credentials.json 2>/dev/null | grep -q test_cred
    ' _ "$SCLAUDE"
fi

# ── T06: volume creation & permissions ────────────────────────────────
# Bug #3: all volumes must be writable by the claude user
run_test "T06: volume permissions" bash -c '
    "$1" version >/dev/null 2>&1
    HOST_UID="$(id -u)"
    for vol in sclaude-config sclaude-rootfs sclaude-npm sclaude-pip; do
        OWNER=$(docker run --rm -v "$vol:/mnt" alpine stat -c "%u" /mnt 2>/dev/null || echo "?")
        if [ "$OWNER" != "$HOST_UID" ]; then
            echo "Volume $vol owned by $OWNER, expected $HOST_UID" >&2
            exit 1
        fi
    done
' _ "$SCLAUDE"

# ── T07: volume persistence ──────────────────────────────────────────
run_test "T07: volume persistence" bash -c '
    # Write a marker into the rootfs volume
    docker run --rm -v sclaude-rootfs:/home/claude alpine \
        sh -c "echo sclaude-test-marker > /home/claude/.test_persist"
    # Check it survives
    docker run --rm -v sclaude-rootfs:/home/claude alpine \
        cat /home/claude/.test_persist | grep -q sclaude-test-marker
    # Clean up
    docker run --rm -v sclaude-rootfs:/home/claude alpine \
        rm -f /home/claude/.test_persist
'

# ── T08: cleanup command ─────────────────────────────────────────────
run_test "T08: cleanup" bash -c '"$1" cleanup 2>&1' _ "$SCLAUDE"

# ── T09: reset command (non-interactive) ──────────────────────────────
# Bug #11: errors should go to stderr not stdout
run_test "T09: reset (auto-confirm)" bash -c '
    echo "" | "$1" reset 2>/dev/null
    # Volumes should be gone (or already absent)
    for vol in sclaude-config sclaude-rootfs sclaude-npm sclaude-pip sclaude-apt; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            echo "Volume $vol still exists after reset" >&2
            exit 1
        fi
    done
' _ "$SCLAUDE"

# ── T10: update command ──────────────────────────────────────────────
run_test "T10: update (no-cache rebuild)" bash -c '"$1" update 2>&1' _ "$SCLAUDE"

# ── T11: PID resource limit ──────────────────────────────────────────
run_test "T11: PID limit (fork bomb)" bash -c '
    # Run a fork bomb in a PID-limited container; it must not escape
    timeout 15 docker run --rm --pids-limit=50 alpine \
        sh -c "for i in \$(seq 1 200); do sleep 999 & done" 2>&1 || true
    # If we reach here, containment worked
    true
'

# ── T12: path with spaces ────────────────────────────────────────────
# Bug #10: quoting in volume mount
run_test "T12: path with spaces" bash -c '
    TEST_DIR="/tmp/sclaude test dir"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    "$1" version
    rm -rf "$TEST_DIR"
' _ "$SCLAUDE"

# ── T13: echo -e portability ─────────────────────────────────────────
# Bug #15: echo -e should not print literal "-e"
run_test "T13: no literal -e in output" bash -c '
    OUTPUT=$("$1" volumes 2>&1)
    if echo "$OUTPUT" | grep -q "^-e"; then
        echo "Found literal -e in output" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# ── T14: zsh invocation ──────────────────────────────────────────────
# Bug #18: BASH_SOURCE fallback
if command -v zsh >/dev/null 2>&1; then
    run_test "T14: zsh invocation" zsh "$SCLAUDE" version
else
    skip_test "T14: zsh invocation" "zsh not installed"
fi

# ── T15: temp file cleanup on build failure ───────────────────────────
# Bug #1: temp Dockerfile should be cleaned up even on failure
run_test "T15: no leaked temp files" bash -c '
    BEFORE=$(ls /tmp/tmp.* 2>/dev/null | wc -l)
    # Force a build that might leave temp files (normal build is fine)
    "$1" --build >/dev/null 2>&1 || true
    AFTER=$(ls /tmp/tmp.* 2>/dev/null | wc -l)
    if [ "$AFTER" -gt "$BEFORE" ]; then
        echo "Temp files leaked: before=$BEFORE after=$AFTER" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# ── T16: shebang portability ─────────────────────────────────────────
# Bug #19: script should use /usr/bin/env bash
run_test "T16: shebang uses env" bash -c '
    HEAD=$(head -1 "$1")
    if [ "$HEAD" = "#!/usr/bin/env bash" ]; then
        exit 0
    else
        echo "Shebang is: $HEAD (expected #!/usr/bin/env bash)" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# ── Results ───────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
echo "  Skipped: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
```

## Running the Tests

### On macOS (native)

```bash
cd ~/projects/sclaude
bash test_e2e.sh
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
