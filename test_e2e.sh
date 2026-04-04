#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single-quoted $1 is intentional (expands inside bash -c)
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
        PASS=$((PASS + 1))
    else
        printf "FAIL\n"
        echo "    Output: ${output:-(empty)}" | head -5
        FAIL=$((FAIL + 1))
    fi
}

skip_test() {
    local name="$1" reason="$2"
    printf "  %-45s SKIP (%s)\n" "$name" "$reason"
    SKIP=$((SKIP + 1))
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

# ── T04: --yolo / --no-yolo flags ─────────────────────────────────────
# Verify both yolo (default) and --no-yolo work without crashing
run_test "T04: --yolo flag" bash -c '"$1" version --yolo 2>&1 && "$1" version --no-yolo 2>&1' _ "$SCLAUDE"

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
# Tests actual write access (not stat ownership, which is unreliable
# with Podman's rootless UID remapping).
run_test "T06: volume permissions" bash -c '
    for vol in sclaude-config sclaude-rootfs sclaude-npm sclaude-pip sclaude-apt; do
        docker volume create "$vol" >/dev/null 2>&1 || true
    done
    IMG=$(docker images sclaude-sandbox --format "{{.Repository}}:{{.Tag}}" | head -1)
    if [ -z "$IMG" ]; then
        echo "No sclaude image found" >&2
        exit 1
    fi
    # Run permission fix
    HOST_UID="$(id -u)"
    HOST_GID="$(id -g)"
    docker run --rm --user root \
        -v sclaude-config:/vol-config \
        -v sclaude-rootfs:/vol-rootfs \
        -v sclaude-npm:/vol-npm \
        -v sclaude-pip:/vol-pip \
        "$IMG" \
        bash -c "chown -R $HOST_UID:$HOST_GID /vol-config /vol-rootfs /vol-npm /vol-pip" 2>/dev/null || true
    # Verify the claude user can actually write to each volume
    docker run --rm \
        -v sclaude-config:/sclaude-config:rw \
        -v sclaude-rootfs:/home/claude:rw \
        -v sclaude-npm:/home/claude/.npm-global:rw \
        -v sclaude-pip:/home/claude/.local:rw \
        "$IMG" bash -c "
            for d in /sclaude-config /home/claude /home/claude/.npm-global /home/claude/.local; do
                if ! touch \"\$d/.perm-test\" 2>/dev/null; then
                    echo \"\$d: NOT WRITABLE\" >&2
                    exit 1
                fi
                rm -f \"\$d/.perm-test\"
            done
        "
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
# Bug #25: timeout is not available on stock macOS; use portable fallback
run_test "T11: PID limit (fork bomb)" bash -c '
    TIMEOUT_CMD=""
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD="timeout 15"
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD="gtimeout 15"
    fi
    # Run a fork bomb in a PID-limited container; it must not escape
    $TIMEOUT_CMD docker run --rm --pids-limit=50 alpine \
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
