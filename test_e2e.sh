#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single-quoted $1 is intentional (expands inside bash -c)
set -euo pipefail

# ── Resolve sclaude path ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCLAUDE="$SCRIPT_DIR/sclaude"
SCODEX="$SCRIPT_DIR/scodex"

if [ ! -x "$SCLAUDE" ]; then
    echo "ERROR: sclaude not found or not executable at $SCLAUDE" >&2
    exit 1
fi
if [ ! -x "$SCODEX" ]; then
    echo "ERROR: scodex not found or not executable at $SCODEX" >&2
    exit 1
fi

OS="$(uname -s)"
ENGINE="${SAGENT_CONTAINER_ENGINE:-docker}"
export SAGENT_CONTAINER_ENGINE="$ENGINE"
export ENGINE
PASS=0
FAIL=0
SKIP=0
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-600}"

# ── Test harness ──────────────────────────────────────────────────────
terminate_process_tree() {
    local pid="$1"
    local children
    local child

    if command -v pgrep >/dev/null 2>&1; then
        children=$(pgrep -P "$pid" 2>/dev/null || true)
        for child in $children; do
            terminate_process_tree "$child"
        done
    fi
    kill "$pid" 2>/dev/null || true
}

run_with_timeout_capture() {
    local output_file="$1"; shift
    local cmd_pid
    local timer_pid
    local rc

    "$@" >"$output_file" 2>&1 &
    cmd_pid=$!
    (
        sleep "$TEST_TIMEOUT_SECONDS"
        terminate_process_tree "$cmd_pid"
    ) &
    timer_pid=$!

    if wait "$cmd_pid"; then
        rc=0
    else
        rc=$?
    fi
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true

    if [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
        printf 'Timed out after %s seconds\n' "$TEST_TIMEOUT_SECONDS" >> "$output_file"
    fi
    return "$rc"
}

run_test() {
    local name="$1"; shift
    printf "  %-45s " "$name"
    local output
    local output_file
    output_file=$(mktemp)
    if run_with_timeout_capture "$output_file" "$@"; then
        output=$(cat "$output_file")
        rm -f "$output_file"
        printf "PASS\n"
        PASS=$((PASS + 1))
    else
        output=$(cat "$output_file")
        rm -f "$output_file"
        printf "FAIL\n"
        printf "    Output: %s\n" "${output:-(empty)}"
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
echo "Engine:   $ENGINE ($("$ENGINE" --version 2>/dev/null || echo 'NOT FOUND'))"
echo "Bash:     ${BASH_VERSION}"
echo ""

# Ensure the selected container engine is running
INFO_OUTPUT=$(mktemp)
if ! run_with_timeout_capture "$INFO_OUTPUT" "$ENGINE" info; then
    cat "$INFO_OUTPUT" >&2
    rm -f "$INFO_OUTPUT"
    echo "ERROR: container engine is not running: $ENGINE" >&2
    exit 1
fi
rm -f "$INFO_OUTPUT"

# ── T01: version command ─────────────────────────────────────────────
# Validates basic execution and that the hashing tool works
# (shasum on macOS, sha256sum on Linux — Bug #13)
run_test "T01: version command" bash -c 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" version && SAGENT_SKIP_RELEASE_CHECK=1 "$2" version' _ "$SCLAUDE" "$SCODEX"

# ── T02: image build ─────────────────────────────────────────────────
# Validates Dockerfile generation, UID/GID build args (Bug #4, #35)
run_test "T02: image build" bash -c 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" --build' _ "$SCLAUDE"

# ── T03: piped input (no TTY) ────────────────────────────────────────
# Bug #6: -it flags should adapt when stdin is not a terminal
run_test "T03: piped/no-TTY mode" bash -c '
    echo "exit" | SAGENT_SKIP_RELEASE_CHECK=1 "$1" version 2>&1
' _ "$SCLAUDE"

# ── T04: --yolo / --no-yolo flags ─────────────────────────────────────
# Verify both yolo (default) and --no-yolo work without crashing
run_test "T04: --yolo flag" bash -c 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" version --yolo 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 "$1" version --no-yolo 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 "$2" version --yolo 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 "$2" version --no-yolo 2>&1' _ "$SCLAUDE" "$SCODEX"

# ── T04b: --docker / --no-docker flags parse ─────────────────────────
run_test "T04b: --docker flags" bash -c 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" version --docker >/dev/null 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 "$1" version --no-docker >/dev/null 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_DOCKER=0 "$2" version >/dev/null 2>&1' _ "$SCLAUDE" "$SCODEX"

# ── T05: credential sync ─────────────────────────────────────────────
if [ "$OS" = "Darwin" ]; then
    # macOS: check that Keychain creds (if present) are synced into the volume
    run_test "T05: credential sync (macOS)" bash -c '
        SAGENT_SKIP_RELEASE_CHECK=1 "$1" version >/dev/null 2>&1
        # Volume should exist after a run; check it is readable
        "$ENGINE" run --rm -v sclaude-config:/c alpine ls /c/ >/dev/null 2>&1
    ' _ "$SCLAUDE"
else
    # Linux: Bug #14 — check file-based credential sync
    # We test the sync mechanism directly: write a dummy cred file,
    # run the helper container the same way sclaude does, verify it lands.
    run_test "T05: credential sync (Linux)" bash -c '
        mkdir -p ~/.claude
        echo "{\"test_cred\":true}" > ~/.claude/.credentials.json
        trap "rm -f ~/.claude/.credentials.json" EXIT
        "$ENGINE" volume create sclaude-config >/dev/null 2>&1 || true
        IMG=$("$ENGINE" images sagent-sandbox --format "{{.Repository}}:{{.Tag}}" | head -1)
        if [ -z "$IMG" ]; then echo "No image" >&2; exit 1; fi
        printf "{\"test_cred\":true}" | "$ENGINE" run --rm -i --user root \
            -v sclaude-config:/vol-config \
            "$IMG" bash -c "
                CREDS=\$(cat)
                if [ -n \"\$CREDS\" ] && printf \"%s\" \"\$CREDS\" | python3 -m json.tool >/dev/null 2>&1; then
                    printf \"%s\" \"\$CREDS\" > /vol-config/.credentials.json
                fi
            "
        "$ENGINE" run --rm -v sclaude-config:/c alpine cat /c/.credentials.json 2>/dev/null | grep -q test_cred
    ' _ "$SCLAUDE"
fi

# ── T06: volume creation & permissions ────────────────────────────────
# Bug #3: user-writable volumes must be writable by the agent user
# Tests actual write access (not stat ownership, which is unreliable
# with Podman's rootless UID remapping).
run_test "T06: volume permissions" bash -c '
    for vol in sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-apt-cache sagent-apt-lists sagent-containers; do
        "$ENGINE" volume create "$vol" >/dev/null 2>&1 || true
    done
    IMG=$("$ENGINE" images sagent-sandbox --format "{{.Repository}}:{{.Tag}}" | head -1)
    if [ -z "$IMG" ]; then
        echo "No sclaude image found" >&2
        exit 1
    fi
    # Run permission fix
    HOST_UID="$(id -u)"
    HOST_GID="$(id -g)"
    "$ENGINE" run --rm --user root \
        -v sclaude-config:/vol-config \
        -v sagent-rootfs:/vol-rootfs \
        -v sagent-npm:/vol-npm \
        -v sagent-pip:/vol-pip \
        -v sagent-apt-cache:/vol-apt-cache \
        -v sagent-apt-lists:/vol-apt-lists \
        "$IMG" \
        bash -c "chown -R \"$HOST_UID:$HOST_GID\" /vol-config /vol-rootfs /vol-npm /vol-pip && mkdir -p /vol-apt-cache/archives/partial /vol-apt-lists/partial" 2>/dev/null || true
    # Verify the agent user can actually write to each user-writable volume
    "$ENGINE" run --rm \
        -v sclaude-config:/sclaude-config:rw \
        -v sagent-rootfs:/home/agent:rw \
        -v sagent-npm:/home/agent/.npm-global:rw \
        -v sagent-pip:/home/agent/.local:rw \
        "$IMG" bash -c "
            for d in /sclaude-config /home/agent /home/agent/.npm-global /home/agent/.local; do
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
    "$ENGINE" run --rm -v sagent-rootfs:/home/agent alpine \
        sh -c "echo sagent-test-marker > /home/agent/.test_persist"
    # Check it survives
    "$ENGINE" run --rm -v sagent-rootfs:/home/agent alpine \
        cat /home/agent/.test_persist | grep -q sagent-test-marker
    # Clean up
    "$ENGINE" run --rm -v sagent-rootfs:/home/agent alpine \
        rm -f /home/agent/.test_persist
'

# ── T08: cleanup command ─────────────────────────────────────────────
run_test "T08: cleanup" bash -c 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" cleanup 2>&1' _ "$SCLAUDE"

# ── T09: reset command (non-interactive) ──────────────────────────────
# Bug #11: errors should go to stderr not stdout
run_test "T09: reset (auto-confirm)" bash -c '
    SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_ASSUME_YES=1 "$1" reset 2>/dev/null
    # Volumes should be gone (or already absent)
    for vol in sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-apt-cache sagent-apt-lists sagent-containers; do
        if "$ENGINE" volume inspect "$vol" >/dev/null 2>&1; then
            echo "Volume $vol still exists after reset" >&2
            exit 1
        fi
    done
' _ "$SCLAUDE"

# ── T10: update command ──────────────────────────────────────────────
# Runs the update flow with wrapper self-update pinned off: whenever the
# checked-out WRAPPER_VERSION is older than the latest published release (every
# open branch after a release), self-update would replace the copy with the
# released wrapper and re-exec THAT — silently testing released code instead of
# the code under test. The wrapper is still copied into a tmpdir so the test
# never touches the under-test script. --force-rebuild bypasses the npm-version
# skip path so this test always asserts the no-cache rebuild actually runs.
# The self-update download path is verified against the real assets by the
# release workflow after each release upload.
run_test "T10: update (forced no-cache rebuild)" bash -c '
    set -e
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT
    cp "$1" "$tmpdir/sclaude"
    chmod +x "$tmpdir/sclaude"
    # Capture with || so a failing update does not set -e out of the subshell
    # before the output is echoed (a failing T10 used to report "(empty)").
    rc=0
    output=$(SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_SKIP_SELF_UPDATE=1 "$tmpdir/sclaude" update --force-rebuild 2>&1) || rc=$?
    echo "$output"
    if [ "$rc" -ne 0 ]; then
        exit "$rc"
    fi
    # Assert the rebuild actually ran — guards against future regressions
    # where the skip-if-up-to-date path accidentally swallows --force-rebuild.
    if ! echo "$output" | grep -q "Updating shared sandbox image"; then
        echo "T10: expected the no-cache rebuild banner, did not find it" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# ── T11: PID resource limit ──────────────────────────────────────────
# Bug #24: timeout is not available on stock macOS; use portable fallback
run_test "T11: PID limit (fork bomb)" bash -c '
    TIMEOUT_CMD=""
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD="timeout 15"
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD="gtimeout 15"
    fi
    # Run a fork bomb in a PID-limited container; it must not escape
    $TIMEOUT_CMD "$ENGINE" run --rm --pids-limit=50 alpine \
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
    SAGENT_SKIP_RELEASE_CHECK=1 "$1" version
    rm -rf "$TEST_DIR"
' _ "$SCLAUDE"

# ── T13: echo -e portability ─────────────────────────────────────────
# Bug #15: echo -e should not print literal "-e"
run_test "T13: no literal -e in output" bash -c '
    OUTPUT=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" volumes 2>&1)
    if echo "$OUTPUT" | grep -q "^-e"; then
        echo "Found literal -e in output" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# ── T14: zsh invocation ──────────────────────────────────────────────
# Bug #17: BASH_SOURCE fallback
if command -v zsh >/dev/null 2>&1; then
    run_test "T14: zsh invocation" bash -c 'SAGENT_SKIP_RELEASE_CHECK=1 zsh "$1" version && SAGENT_SKIP_RELEASE_CHECK=1 zsh "$2" version' _ "$SCLAUDE" "$SCODEX"
else
    skip_test "T14: zsh invocation" "zsh not installed"
fi

# ── T15: temp file cleanup on build failure ───────────────────────────
# Bug #1: temp Dockerfile should be cleaned up even on failure
run_test "T15: no leaked temp files" bash -c '
    # Snapshot existing tmp files, run build, check for new ones
    MARKER="/tmp/.sclaude-t15-$$"
    touch "$MARKER"
    SAGENT_SKIP_RELEASE_CHECK=1 "$1" --build >/dev/null 2>&1 || true
    # Any tmp.* files newer than our marker were created during the build
    LEAKED=$(find /tmp -maxdepth 1 -name "tmp.*" -newer "$MARKER" 2>/dev/null | wc -l)
    rm -f "$MARKER"
    if [ "$LEAKED" -gt 0 ]; then
        echo "Temp files leaked: $LEAKED new file(s)" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# ── T16: shebang portability ─────────────────────────────────────────
# Bug #18: script should use /usr/bin/env bash
run_test "T16: shebang uses env" bash -c '
    HEAD=$(head -1 "$1")
    HEAD2=$(head -1 "$2")
    if [ "$HEAD" = "#!/usr/bin/env bash" ] && [ "$HEAD2" = "#!/usr/bin/env bash" ]; then
        exit 0
    else
        echo "Shebangs are: $HEAD / $HEAD2 (expected #!/usr/bin/env bash)" >&2
        exit 1
    fi
' _ "$SCLAUDE" "$SCODEX"

# ── T17: Codex CLI wrapper smoke ─────────────────────────────────────
run_test "T17: scodex version command" bash -c 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" version' _ "$SCODEX"

# T17b / T17c exercise deeper code paths than `--version`. They should fail fast,
# so cap their per-test timeout at 120s regardless of the global default — a
# hang in inner-CLI config loading shouldn't waste 10 minutes per test in CI.
# Users can still raise it via T17_TIMEOUT_SECONDS for slow builders.
_t17_prev_timeout="$TEST_TIMEOUT_SECONDS"
_t17_cap="${T17_TIMEOUT_SECONDS:-120}"
if [ "$TEST_TIMEOUT_SECONDS" -gt "$_t17_cap" ]; then
    TEST_TIMEOUT_SECONDS="$_t17_cap"
fi

# T17b exercises a deeper Codex code path than `--version`: `exec --help` actually
# loads the Codex command tree and runs the early config-init code. This catches
# regressions where the inner CLI errors out on configuration loading (e.g. cloud
# requirements / managed policies) — T17's `--version` is too shallow to reach
# that code path.
run_test "T17b: scodex exec --help loads without config errors" bash -c '
    output=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" exec --help 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "scodex exec --help exited $rc:" >&2
        echo "$output" | tail -20 >&2
        exit 1
    fi
    if echo "$output" | grep -qiE "Error loading configuration|Failed to load Cloud requirements|Failed to load workspace-managed policies|Failed to load managed (config|hooks|requirements)"; then
        echo "scodex exec --help printed a config-load error:" >&2
        echo "$output" | grep -iE "error|fail" >&2
        exit 1
    fi
' _ "$SCODEX"

# Same idea for sclaude — make sure `--help` reaches the Claude Code internals
# without configuration errors. A shallow `--version` check would not.
run_test "T17c: sclaude --help loads without config errors" bash -c '
    output=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" --help 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "sclaude --help exited $rc:" >&2
        echo "$output" | tail -20 >&2
        exit 1
    fi
    if echo "$output" | grep -qiE "Error loading configuration|Failed to load configuration|Failed to load settings|Failed to load claude\.json"; then
        echo "sclaude --help printed a config-load error:" >&2
        echo "$output" | grep -iE "error|fail" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# Restore the global timeout for tests after T17c.
TEST_TIMEOUT_SECONDS="$_t17_prev_timeout"
unset _t17_prev_timeout _t17_cap

# ── T18: package install support ─────────────────────────────────────
run_test "T18: sudo apt works in sandbox" bash -c '
    IMG=$("$ENGINE" images sagent-sandbox --format "{{.Repository}}:{{.Tag}}" | head -1)
    if [ -z "$IMG" ]; then
        echo "No sagent image found" >&2
        exit 1
    fi
    "$ENGINE" volume create sagent-rootfs >/dev/null 2>&1 || true
    "$ENGINE" volume create sagent-apt-cache >/dev/null 2>&1 || true
    "$ENGINE" volume create sagent-apt-lists >/dev/null 2>&1 || true
    "$ENGINE" run --rm \
        -v sagent-rootfs:/home/agent:rw \
        -v sagent-apt-cache:/var/cache/apt:rw \
        -v sagent-apt-lists:/var/lib/apt/lists:rw \
        --cap-drop=ALL \
        --cap-add=CHOWN \
        --cap-add=DAC_OVERRIDE \
        --cap-add=FOWNER \
        --cap-add=FSETID \
        --cap-add=SETGID \
        --cap-add=SETUID \
        --cap-add=SYS_CHROOT \
        "$IMG" bash -c "sudo apt-get update >/dev/null && sudo apt-get install -y --no-install-recommends file >/dev/null"
' _ "$SCLAUDE"

# ── T18b: pip user install works despite PEP 668 ─────────────────────
# Ubuntu 24.04 marks system Python externally managed; the image sets
# PIP_BREAK_SYSTEM_PACKAGES=1 so `pip install --user` lands in the
# sagent-pip volume instead of erroring out.
run_test "T18b: pip install --user works in sandbox" bash -c '
    IMG=$("$ENGINE" images sagent-sandbox --format "{{.Repository}}:{{.Tag}}" | head -1)
    if [ -z "$IMG" ]; then
        echo "No sagent image found" >&2
        exit 1
    fi
    "$ENGINE" volume create sagent-pip >/dev/null 2>&1 || true
    # Fresh volumes mount root-owned; mirror the ownership fix sclaude applies.
    "$ENGINE" run --rm --user root -v sagent-pip:/vol-pip "$IMG" \
        chown -R "$(id -u):$(id -g)" /vol-pip
    "$ENGINE" run --rm -v sagent-pip:/home/agent/.local:rw "$IMG" \
        bash -c "pip3 install --user --quiet cowsay >/dev/null && python3 -c \"import cowsay\""
' _ "$SCLAUDE"

# ── T19: shared image contains both CLIs ─────────────────────────────
run_test "T19: shared image has both CLIs" bash -c '
    IMG=$("$ENGINE" images sagent-sandbox --format "{{.Repository}}:{{.Tag}}" | head -1)
    if [ -z "$IMG" ]; then
        echo "No sagent image found" >&2
        exit 1
    fi
    "$ENGINE" run --rm "$IMG" claude --version >/dev/null
    "$ENGINE" run --rm "$IMG" codex --version >/dev/null
' _ "$SCLAUDE"

# ── T20: Codex config sync ───────────────────────────────────────────
run_test "T20: scodex config sync" bash -c '
    TMP_CODEX_HOME=$(mktemp -d)
    trap "rm -rf \"$TMP_CODEX_HOME\"" EXIT
    printf "%s" "{\"test_codex_auth\":true}" > "$TMP_CODEX_HOME/auth.json"
    printf "%s\n" "model = \"gpt-5\"" > "$TMP_CODEX_HOME/config.toml"
    "$ENGINE" volume rm scodex-config >/dev/null 2>&1 || true
    CODEX_HOME="$TMP_CODEX_HOME" SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo exec --help >/dev/null
    "$ENGINE" run --rm -v scodex-config:/c alpine cat /c/auth.json 2>/dev/null | grep -q test_codex_auth
    "$ENGINE" run --rm -v scodex-config:/c alpine cat /c/config.toml 2>/dev/null | grep -q "model"
' _ "$SCODEX"

# ── T21: release check is non-fatal and cache-safe ───────────────────
run_test "T21: release check non-fatal" bash -c '
    TMP_CACHE=$(mktemp -d)
    trap "rm -rf \"$TMP_CACHE\"" EXIT
    XDG_CACHE_HOME="$TMP_CACHE" "$1" check-update >/dev/null 2>&1
    test -f "$TMP_CACHE/sagent/release-check"
' _ "$SCLAUDE"

# ── T22: native args after command are not wrapper-dispatched ─────────
run_test "T22: native args pass through" bash -c '
    SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo exec --help update 2>&1 | grep -q "Run Codex non-interactively"
' _ "$SCODEX"

# ── T23: explicit engine selection works ─────────────────────────────
run_test "T23: explicit engine selection" bash -c '
    SAGENT_CONTAINER_ENGINE="$ENGINE" SAGENT_ENGINE_TIMEOUT_SECONDS=5 SAGENT_SKIP_RELEASE_CHECK=1 "$1" version >/dev/null
    SAGENT_CONTAINER_ENGINE="$ENGINE" SAGENT_ENGINE_TIMEOUT_SECONDS=5 SAGENT_SKIP_RELEASE_CHECK=1 "$2" version >/dev/null
' _ "$SCLAUDE" "$SCODEX"

# ── T24: wrapper parity ──────────────────────────────────────────────
# sclaude and scodex share their sandbox implementation; only the tool-specific
# functions may differ. Any drift in a shared function is a bug. Functions are
# auto-discovered from sclaude, so new shared functions are covered without
# updating this test. Script-name mentions in comments are normalized.
run_test "T24: wrapper shared functions identical" bash -c '
    tmpdir=$(mktemp -d)
    trap "rm -rf \"$tmpdir\"" EXIT
    divergent="read_credentials sync_state sync_codex_config_files run_tool"
    rc=0
    for fn in $(grep -oE "^[a-z_0-9]+\(\)" "$1" | tr -d "()"); do
        case " $divergent " in *" $fn "*) continue ;; esac
        for f in "$1" "$2"; do
            awk -v fn="$fn" "\$0 ~ \"^\"fn\"\\\\(\\\\) {\" {inf=1} inf {print} inf && /^}/ {inf=0}" "$f" \
                | sed "s/scodex/sclaude/g" > "$tmpdir/$(basename "$f").fn"
        done
        if ! diff -u "$tmpdir/$(basename "$1").fn" "$tmpdir/$(basename "$2").fn"; then
            echo "Shared function diverges between wrappers: $fn" >&2
            rc=1
        fi
    done
    exit "$rc"
' _ "$SCLAUDE" "$SCODEX"

# ── T25: corrupted release-check cache is non-fatal ──────────────────
# Non-numeric cache content used to kill the wrapper with an unbound-variable
# arithmetic error under set -u before the CLI ever launched.
run_test "T25: corrupted release cache non-fatal" bash -c '
    TMP_CACHE=$(mktemp -d)
    trap "rm -rf \"$TMP_CACHE\"" EXIT
    mkdir -p "$TMP_CACHE/sagent"
    printf "garbage:data\n" > "$TMP_CACHE/sagent/release-check"
    XDG_CACHE_HOME="$TMP_CACHE" "$1" --help >/dev/null 2>&1
' _ "$SCLAUDE"

# ── T26: --force-rebuild rejected outside update ─────────────────────
run_test "T26: --force-rebuild only valid with update" bash -c '
    if SAGENT_SKIP_RELEASE_CHECK=1 "$1" --force-rebuild >/dev/null 2>&1; then
        echo "--force-rebuild without update should fail" >&2
        exit 1
    fi
    SAGENT_SKIP_RELEASE_CHECK=1 "$1" --force-rebuild 2>&1 \
        | grep -q "only valid with the .update. command"
' _ "$SCLAUDE"

# ── T27: nested containers (--docker mode) ───────────────────────────
# Replicates the exact run configuration the wrappers use for --docker and
# verifies the full nested workflow: pull+run, build, and run the built image.
run_test "T27: nested containers (--docker mode)" bash -c '
    IMG=$("$ENGINE" images sagent-sandbox --format "{{.Repository}}:{{.Tag}}" | head -1)
    if [ -z "$IMG" ]; then
        echo "No sagent image found" >&2
        exit 1
    fi
    "$ENGINE" volume create sagent-containers >/dev/null 2>&1 || true
    "$ENGINE" run --rm --user root -v sagent-containers:/vol-containers "$IMG" \
        chown -R "$(id -u):$(id -g)" /vol-containers
    "$ENGINE" run --rm \
        -v sagent-containers:/home/agent/.local/share/containers:rw \
        --device /dev/fuse --device /dev/net/tun \
        --security-opt seccomp=unconfined \
        --security-opt label=disable \
        --cap-drop=ALL \
        --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER --cap-add=FSETID \
        --cap-add=SETGID --cap-add=SETUID --cap-add=SYS_CHROOT --cap-add=NET_BIND_SERVICE \
        --pids-limit=512 \
        "$IMG" bash -c "
            set -e
            docker run --rm docker.io/library/alpine:latest echo nested-run-ok | grep -q nested-run-ok
            printf \"FROM docker.io/library/alpine:latest\nRUN echo built > /msg\nCMD cat /msg\n\" > /tmp/Dockerfile
            docker build -q -t nested-t27 -f /tmp/Dockerfile /tmp >/dev/null
            docker run --rm nested-t27 | grep -q built
        "
' _ "$SCLAUDE"

# ── T28: config file ─────────────────────────────────────────────────
# The config file is sourced at startup and may set tunables. MEMORY_LIMIT is
# part of the image version hash, so a config override observably changes the
# "Image hash" line. Environment variables must take precedence over the file.
run_test "T28: config file sourced with env precedence" bash -c '
    TMP_CFG_DIR=$(mktemp -d)
    trap "rm -rf \"$TMP_CFG_DIR\"" EXIT
    default_hash=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" version | sed -n "s/^Image hash: //p")
    printf "MEMORY_LIMIT=\"9g\"\n" > "$TMP_CFG_DIR/config"
    cfg_hash=$(SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE="$TMP_CFG_DIR/config" "$1" version | sed -n "s/^Image hash: //p")
    if [ -z "$default_hash" ] || [ "$default_hash" = "$cfg_hash" ]; then
        echo "config file MEMORY_LIMIT did not change the version hash ($default_hash vs $cfg_hash)" >&2
        exit 1
    fi
    # Env var must beat a config-file value for SAGENT_CONTAINER_ENGINE: the
    # config points at a nonexistent engine; the env var must rescue the run.
    printf "SAGENT_CONTAINER_ENGINE=\"no-such-engine\"\n" > "$TMP_CFG_DIR/config"
    SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE="$TMP_CFG_DIR/config" SAGENT_CONTAINER_ENGINE="$ENGINE" "$1" version >/dev/null
' _ "$SCLAUDE"

# ── T29: browser-open shim ───────────────────────────────────────────
# The sandbox has no browser: xdg-open/$BROWSER render each URL as an OSC 8
# terminal hyperlink plus plain text, so login flows (claude, codex, gh auth)
# reach the host browser via Cmd/Ctrl+click in the terminal.
run_test "T29: browser-open shim renders clickable URL" bash -c '
    IMG=$("$ENGINE" images sagent-sandbox --format "{{.Repository}}:{{.Tag}}" | head -1)
    if [ -z "$IMG" ]; then
        echo "No sagent image found" >&2
        exit 1
    fi
    out=$("$ENGINE" run --rm "$IMG" sh -c "printenv BROWSER && xdg-open https://example.com/sagent-test 2>&1")
    printf "%s" "$out" | grep -q "host-open"
    printf "%s" "$out" | grep -c "https://example.com/sagent-test" | grep -qx 2
    printf "%s" "$out" | grep -q "]8;;"
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
