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
# Where tests create directories that get bind-mounted into containers. VM-backed
# engines only resolve paths under their shared mounts (Rancher Desktop shares
# just $HOME), so such jobs point this somewhere under the home directory.
SAGENT_TEST_TMPDIR="${SAGENT_TEST_TMPDIR:-/tmp}"
export SAGENT_TEST_TMPDIR
# Tests that replicate run_tool's bind mounts need the wrapper's rootless-podman
# user mapping too (#75); empty on every other engine.
SAGENT_TEST_USERNS=""
if [ "$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
    SAGENT_TEST_USERNS="--userns=keep-id:uid=$(id -u),gid=$(id -g)"
fi
export SAGENT_TEST_USERNS
export SAGENT_CONTAINER_ENGINE="$ENGINE"
export ENGINE

# shellcheck source=test_lib.sh disable=SC1091
. "$SCRIPT_DIR/test_lib.sh"

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
run_test "T01: version command" bash -ec 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" version && SAGENT_SKIP_RELEASE_CHECK=1 "$2" version' _ "$SCLAUDE" "$SCODEX"

# ── T02: image build ─────────────────────────────────────────────────
run_test "T02: image build" bash -ec 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" --build' _ "$SCLAUDE"

# Image under test, computed once right after the build: per-test derivation
# through `version` proved flaky under daemon load (its engine probe has a
# bounded timeout), and `images | head -1` ordering is unreliable (#61).
SUITE_IMG="sagent-sandbox:$(SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_ENGINE_TIMEOUT_SECONDS=60 "$SCLAUDE" version 2>/dev/null | sed -n 's/^Image hash: //p')"
export SUITE_IMG

# ── T03: piped input (no TTY) ────────────────────────────────────────
run_test "T03: piped/no-TTY mode" bash -ec '
    echo "exit" | SAGENT_SKIP_RELEASE_CHECK=1 "$1" version 2>&1
' _ "$SCLAUDE"

# ── T04: --yolo / --no-yolo flags ─────────────────────────────────────
run_test "T04: --yolo flag" bash -ec 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" version --yolo 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 "$1" version --no-yolo 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 "$2" version --yolo 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 "$2" version --no-yolo 2>&1' _ "$SCLAUDE" "$SCODEX"

# ── T04b: --docker / --no-docker flags parse ─────────────────────────
run_test "T04b: --docker flags" bash -ec 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" version --docker >/dev/null 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 "$1" version --no-docker >/dev/null 2>&1 && SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_DOCKER=0 "$2" version >/dev/null 2>&1' _ "$SCLAUDE" "$SCODEX"

# ── T05: credential sync ─────────────────────────────────────────────
if [ "$OS" = "Darwin" ]; then
    run_test "T05: credential sync (macOS)" bash -ec '
        SAGENT_SKIP_RELEASE_CHECK=1 "$1" version >/dev/null 2>&1
        "$ENGINE" run --rm -v sclaude-config:/c alpine ls /c/ >/dev/null 2>&1
    ' _ "$SCLAUDE"
else
    run_test "T05: credential sync (Linux)" bash -ec '
        mkdir -p ~/.claude
        echo "{\"test_cred\":true}" > ~/.claude/.credentials.json
        trap "rm -f ~/.claude/.credentials.json" EXIT
        "$ENGINE" volume create sclaude-config >/dev/null 2>&1 || true
        IMG="$SUITE_IMG"
        if ! "$ENGINE" image inspect "$IMG" >/dev/null 2>&1; then echo "No image" >&2; exit 1; fi
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
# Tests actual write access (not stat ownership, which is unreliable
# with Podman's rootless UID remapping).
run_test "T06: volume permissions" bash -ec '
    for vol in sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-apt-cache sagent-apt-lists sagent-containers; do
        "$ENGINE" volume create "$vol" >/dev/null 2>&1 || true
    done
    IMG="$SUITE_IMG"
    if ! "$ENGINE" image inspect "$IMG" >/dev/null 2>&1; then
        echo "No sclaude image found" >&2
        exit 1
    fi
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
run_test "T07: volume persistence" bash -ec '
    "$ENGINE" run --rm -v sagent-rootfs:/home/agent alpine \
        sh -c "echo sagent-test-marker > /home/agent/.test_persist"
    "$ENGINE" run --rm -v sagent-rootfs:/home/agent alpine \
        cat /home/agent/.test_persist | grep -q sagent-test-marker
    "$ENGINE" run --rm -v sagent-rootfs:/home/agent alpine \
        rm -f /home/agent/.test_persist
'

# ── T08: cleanup command ─────────────────────────────────────────────
run_test "T08: cleanup" bash -ec 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" cleanup 2>&1' _ "$SCLAUDE"

# ── T09: reset command (non-interactive) ──────────────────────────────
run_test "T09: reset (auto-confirm)" bash -ec '
    SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_ASSUME_YES=1 "$1" reset
    for vol in sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-apt-cache sagent-apt-lists sagent-containers; do
        if "$ENGINE" volume inspect "$vol" >/dev/null 2>&1; then
            echo "Volume $vol still exists after reset" >&2
            exit 1
        fi
    done
' _ "$SCLAUDE"

# ── T09b: reset fails loudly on volumes pinned by running containers ──
# #64: reset must not report success while a running container keeps a
# volume alive.
run_test "T09b: reset reports pinned volumes" bash -ec '
    "$ENGINE" volume create sclaude-config >/dev/null 2>&1 || true
    "$ENGINE" run -d --name sagent-t09b-pinner -v sclaude-config:/c "$SUITE_IMG" sleep 120 >/dev/null
    trap "\"$ENGINE\" rm -f sagent-t09b-pinner >/dev/null 2>&1" EXIT
    if SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_ASSUME_YES=1 "$1" reset 2>/tmp/t09b-err; then
        echo "reset should have failed while a running container pins sclaude-config" >&2
        exit 1
    fi
    grep -q "still in use by a container, not removed: sclaude-config" /tmp/t09b-err
    rm -f /tmp/t09b-err
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
run_test "T10: update (forced no-cache rebuild)" bash -ec '
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
run_test "T11: PID limit (fork bomb)" bash -ec '
    TIMEOUT_CMD=""
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD="timeout 15"
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD="gtimeout 15"
    fi
    # Run a fork bomb in a PID-limited container; it must not escape
    $TIMEOUT_CMD "$ENGINE" run --rm --pids-limit=50 alpine \
        sh -c "for i in \$(seq 1 200); do sleep 999 & done" 2>&1 || true
    true
'

# ── T12: path with spaces ────────────────────────────────────────────
run_test "T12: path with spaces" bash -ec '
    TEST_DIR="$SAGENT_TEST_TMPDIR/sclaude test dir"
    mkdir -p "$TEST_DIR"
    trap "rm -rf \"$TEST_DIR\"" EXIT
    cd "$TEST_DIR"
    SAGENT_SKIP_RELEASE_CHECK=1 "$1" version
    # The mount itself, quoted the way run_tool quotes it.
    echo t12-marker > "$TEST_DIR/probe.txt"
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v "$(pwd -P):$TEST_DIR:rw" -w "$TEST_DIR" "$SUITE_IMG" cat probe.txt | grep -q t12-marker
' _ "$SCLAUDE"

# ── T12b: workspace under /tmp is not shadowed by the tmpfs ──────────
# Replicates run_tool's fixed behavior (#65, #71): with a workspace under /tmp
# the tmpfs is omitted, and the physical path is mounted at the logical path
# (on macOS /tmp is a symlink into /private, which is what a VM-backed engine
# actually shares), so the workspace files are visible inside the sandbox.
run_test "T12b: /tmp workspace visible in sandbox" bash -ec '
    IMG="$SUITE_IMG"
    WS=$(mktemp -d /tmp/sclaude-t12b.XXXXXX)
    trap "rm -rf \"$WS\"" EXIT
    WS_HOST=$(cd "$WS" && pwd -P)
    echo t12b-marker > "$WS/probe.txt"
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v "$WS_HOST:$WS:rw" -w "$WS" "$IMG" \
        sh -c "cat probe.txt && touch written-by-agent"
    grep -q t12b-marker "$WS/probe.txt"
    [ -f "$WS/written-by-agent" ]
    # The wrapper itself must run from a /tmp workspace (exercises run_tool).
    (cd "$WS" && SAGENT_SKIP_RELEASE_CHECK=1 "$1" --help >/dev/null 2>&1)
' _ "$SCLAUDE"

# ── T12c: / as workspace is refused ──────────────────────────────────
# #66: a / workspace would bind the entire host filesystem into the sandbox.
run_test "T12c: / workspace refused" bash -ec '
    if (cd / && SAGENT_SKIP_RELEASE_CHECK=1 "$1" --help >/dev/null 2>/tmp/t12c-err); then
        echo "running from / should have been refused" >&2
        exit 1
    fi
    grep -q "refusing to run with / as the workspace" /tmp/t12c-err
    rm -f /tmp/t12c-err
' _ "$SCLAUDE"

# ── T13: echo -e portability ─────────────────────────────────────────
run_test "T13: no literal -e in output" bash -ec '
    OUTPUT=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" volumes 2>&1)
    if echo "$OUTPUT" | grep -q "^-e"; then
        echo "Found literal -e in output" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# ── T14: zsh invocation ──────────────────────────────────────────────
if command -v zsh >/dev/null 2>&1; then
    run_test "T14: zsh invocation" bash -ec 'SAGENT_SKIP_RELEASE_CHECK=1 zsh "$1" version && SAGENT_SKIP_RELEASE_CHECK=1 zsh "$2" version' _ "$SCLAUDE" "$SCODEX"
else
    skip_test "T14: zsh invocation" "zsh not installed"
fi

# ── T15: temp file cleanup on build failure ───────────────────────────
run_test "T15: no leaked temp files" bash -ec '
    # mktemp honors TMPDIR (macOS sets it under /var/folders), so look there.
    TMP_ROOT="${TMPDIR:-/tmp}"
    MARKER="$TMP_ROOT/.sclaude-t15-$$"
    touch "$MARKER"
    SAGENT_SKIP_RELEASE_CHECK=1 "$1" --build >/dev/null 2>&1 || true
    # Any tmp.* files newer than our marker were created during the build
    LEAKED=$(find "$TMP_ROOT" -maxdepth 1 -name "tmp.*" -newer "$MARKER" 2>/dev/null | wc -l)
    rm -f "$MARKER"
    if [ "$LEAKED" -gt 0 ]; then
        echo "Temp files leaked: $LEAKED new file(s)" >&2
        exit 1
    fi
' _ "$SCLAUDE"

# ── T16: shebang portability ─────────────────────────────────────────
run_test "T16: shebang uses env" bash -ec '
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
run_test "T17: scodex version command" bash -ec 'SAGENT_SKIP_RELEASE_CHECK=1 "$1" version' _ "$SCODEX"

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
run_test "T17b: scodex exec --help loads without config errors" bash -ec '
    rc=0
    output=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" exec --help 2>&1) || rc=$?
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
run_test "T17c: sclaude --help loads without config errors" bash -ec '
    rc=0
    output=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" --help 2>&1) || rc=$?
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
run_test "T18: sudo apt works in sandbox" bash -ec '
    IMG="$SUITE_IMG"
    if ! "$ENGINE" image inspect "$IMG" >/dev/null 2>&1; then
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
run_test "T18b: pip install --user works in sandbox" bash -ec '
    IMG="$SUITE_IMG"
    if ! "$ENGINE" image inspect "$IMG" >/dev/null 2>&1; then
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

# ── T19: shared image contains both CLIs and gh ──────────────────────
run_test "T19: shared image has both CLIs and gh" bash -ec '
    IMG="$SUITE_IMG"
    if ! "$ENGINE" image inspect "$IMG" >/dev/null 2>&1; then
        echo "No sagent image found" >&2
        exit 1
    fi
    "$ENGINE" run --rm "$IMG" claude --version >/dev/null
    "$ENGINE" run --rm "$IMG" codex --version >/dev/null
    "$ENGINE" run --rm "$IMG" gh --version | grep -q "^gh version"
' _ "$SCLAUDE"

# ── T20: Codex config sync ───────────────────────────────────────────
run_test "T20: scodex config sync" bash -ec '
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
run_test "T21: release check non-fatal" bash -ec '
    TMP_CACHE=$(mktemp -d)
    trap "rm -rf \"$TMP_CACHE\"" EXIT
    XDG_CACHE_HOME="$TMP_CACHE" "$1" check-update >/dev/null 2>&1
    test -f "$TMP_CACHE/sagent/release-check"
' _ "$SCLAUDE"

# ── T22: native args after command are not wrapper-dispatched ─────────
run_test "T22: native args pass through" bash -ec '
    SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo exec --help update 2>&1 | grep -q "Run Codex non-interactively"
' _ "$SCODEX"

# ── T23: explicit engine selection works ─────────────────────────────
run_test "T23: explicit engine selection" bash -ec '
    SAGENT_CONTAINER_ENGINE="$ENGINE" SAGENT_ENGINE_TIMEOUT_SECONDS=5 SAGENT_SKIP_RELEASE_CHECK=1 "$1" version >/dev/null
    SAGENT_CONTAINER_ENGINE="$ENGINE" SAGENT_ENGINE_TIMEOUT_SECONDS=5 SAGENT_SKIP_RELEASE_CHECK=1 "$2" version >/dev/null
' _ "$SCLAUDE" "$SCODEX"

# ── T24: wrapper parity ──────────────────────────────────────────────
# sclaude and scodex share their sandbox implementation; only the tool-specific
# functions may differ. Any drift in a shared function is a bug. Functions are
# auto-discovered from sclaude, so new shared functions are covered without
# updating this test. Script-name mentions in comments are normalized.
run_test "T24: wrapper shared functions identical" bash -ec '
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
    # The main dispatch after the function definitions is shared too.
    for f in "$1" "$2"; do
        sed -n "/^parse_args \"\$@\"/,\$p" "$f" | sed "s/scodex/sclaude/g" > "$tmpdir/$(basename "$f").tail"
    done
    if ! diff -u "$tmpdir/$(basename "$1").tail" "$tmpdir/$(basename "$2").tail"; then
        echo "Main dispatch diverges between wrappers" >&2
        rc=1
    fi
    exit "$rc"
' _ "$SCLAUDE" "$SCODEX"

# ── T25: corrupted release-check cache is non-fatal ──────────────────
# Non-numeric cache content used to kill the wrapper with an unbound-variable
# arithmetic error under set -u before the CLI ever launched.
run_test "T25: corrupted release cache non-fatal" bash -ec '
    TMP_CACHE=$(mktemp -d)
    trap "rm -rf \"$TMP_CACHE\"" EXIT
    mkdir -p "$TMP_CACHE/sagent"
    printf "garbage:data\n" > "$TMP_CACHE/sagent/release-check"
    XDG_CACHE_HOME="$TMP_CACHE" "$1" --help >/dev/null 2>&1
' _ "$SCLAUDE"

# ── T26: --force-rebuild rejected outside update ─────────────────────
run_test "T26: --force-rebuild only valid with update" bash -ec '
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
run_test "T27: nested containers (--docker mode)" bash -ec '
    IMG="$SUITE_IMG"
    if ! "$ENGINE" image inspect "$IMG" >/dev/null 2>&1; then
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
        --security-opt apparmor=unconfined \
        --security-opt label=disable \
        --cap-drop=ALL \
        --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER --cap-add=FSETID \
        --cap-add=SETGID --cap-add=SETUID --cap-add=SYS_CHROOT --cap-add=NET_BIND_SERVICE \
        --pids-limit=512 \
        "$IMG" bash -c "
            set -e
            # public.ecr.aws mirror: Docker Hub anonymous pulls are rate-limited
            # per IP, which flakes on shared CI runners.
            docker run --rm public.ecr.aws/docker/library/alpine:latest echo nested-run-ok | grep -q nested-run-ok
            printf \"FROM public.ecr.aws/docker/library/alpine:latest\nRUN echo built > /msg\nCMD cat /msg\n\" > /tmp/Dockerfile
            docker build -q -t nested-t27 -f /tmp/Dockerfile /tmp >/dev/null
            docker run --rm nested-t27 | grep -q built
        "
' _ "$SCLAUDE"

# ── T28: config file ─────────────────────────────────────────────────
# The config file is sourced at startup and may set tunables; a MEMORY_LIMIT
# override is observable in the version output's Limits line. Environment
# variables must take precedence over the file, and a config file with a
# syntax error must fail with a clear message naming the file.
run_test "T28: config file sourced with env precedence" bash -ec '
    TMP_CFG_DIR=$(mktemp -d)
    trap "rm -rf \"$TMP_CFG_DIR\"" EXIT
    printf "MEMORY_LIMIT=\"9g\"\n" > "$TMP_CFG_DIR/config"
    SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE="$TMP_CFG_DIR/config" "$1" version \
        | grep -q "^Limits: memory=9g "
    # Env var must beat a config-file value for SAGENT_CONTAINER_ENGINE: the
    # config points at a nonexistent engine; the env var must rescue the run.
    printf "SAGENT_CONTAINER_ENGINE=\"no-such-engine\"\n" > "$TMP_CFG_DIR/config"
    SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE="$TMP_CFG_DIR/config" SAGENT_CONTAINER_ENGINE="$ENGINE" "$1" version >/dev/null
    # A config file with a syntax error must be rejected with a clear message.
    printf "if then fi(\n" > "$TMP_CFG_DIR/config"
    if SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE="$TMP_CFG_DIR/config" "$1" version >/dev/null 2>"$TMP_CFG_DIR/err"; then
        echo "broken config file should have failed the run" >&2
        exit 1
    fi
    grep -q "config file has a syntax error" "$TMP_CFG_DIR/err"
' _ "$SCLAUDE"

# ── T29: browser-open shim ───────────────────────────────────────────
# The sandbox has no browser: xdg-open/$BROWSER render each URL as an OSC 8
# terminal hyperlink plus plain text, so login flows (claude, codex, gh auth)
# reach the host browser via Cmd/Ctrl+click in the terminal.
run_test "T29: browser-open shim renders clickable URL" bash -ec '
    IMG="$SUITE_IMG"
    if ! "$ENGINE" image inspect "$IMG" >/dev/null 2>&1; then
        echo "No sagent image found" >&2
        exit 1
    fi
    out=$("$ENGINE" run --rm "$IMG" sh -c "printenv BROWSER && xdg-open https://example.com/sagent-test 2>&1")
    printf "%s" "$out" | grep -q "host-open"
    # hyperlink target plus plain-text copy, on one line
    printf "%s" "$out" | grep -o "https://example.com/sagent-test" | grep -c . | grep -qx 2
    printf "%s" "$out" | grep -q "]8;;"
' _ "$SCLAUDE"

# ── T30: sandbox isolation assertions ────────────────────────────────
# Adversarial checks of the security model's core claims (the original design
# plan listed these but they were never implemented): no engine socket is
# reachable, the other tool's secret volume is not mounted, and host files
# beside the workspace do not leak into the sandbox.
run_test "T30: sandbox isolation assertions" bash -ec '
    WS=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t30.XXXXXX")
    SIBLING="$WS-sibling-secret"
    echo leak-canary > "$SIBLING"
    trap "rm -rf \"$WS\" \"$SIBLING\"" EXIT
    "$ENGINE" run --rm $SAGENT_TEST_USERNS \
        -v "$(cd "$WS" && pwd -P):$WS:rw" \
        -v sclaude-config:/sclaude-config:rw \
        -w "$WS" \
        --cap-drop=ALL \
        --security-opt label=disable \
        "$SUITE_IMG" bash -c "
            set -e
            [ ! -e /var/run/docker.sock ]
            [ ! -e /run/docker.sock ]
            [ ! -e /scodex-config ]
            [ ! -e \"$SIBLING\" ]
        "
' _ "$SCLAUDE"

# ── T31: SAGENT_CA_BUNDLE bakes trust anchors into the image ─────────
# #68: behind a TLS-inspecting proxy every HTTPS fetch in the build and in the
# sandbox fails. Builds a second image with a two-certificate bundle and proves
# a server certificate issued by one of those CAs is trusted by curl (system
# store), Python (SSL_CERT_FILE) and Node (NODE_EXTRA_CA_CERTS). Also asserts
# the bundle validation and that the bundle content is part of the image hash.
run_test "T31: SAGENT_CA_BUNDLE trust anchors" bash -ec '
    set -e
    tmp=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t31.XXXXXX")
    trap "rm -rf \"$tmp\"" EXIT
    if SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CA_BUNDLE="$tmp/missing.pem" "$1" version >/dev/null 2>"$tmp/err"; then
        echo "a missing bundle file should have failed the run" >&2
        exit 1
    fi
    grep -q "SAGENT_CA_BUNDLE is not a readable file" "$tmp/err"
    echo "not a certificate" > "$tmp/junk.pem"
    if SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CA_BUNDLE="$tmp/junk.pem" "$1" version >/dev/null 2>"$tmp/err"; then
        echo "a bundle without certificates should have failed the run" >&2
        exit 1
    fi
    grep -q "contains no PEM certificates" "$tmp/err"

    for n in 1 2; do
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=sagent-t31-ca$n" \
            -keyout "$tmp/ca$n.key" -out "$tmp/ca$n.pem" >/dev/null 2>&1
    done
    cat "$tmp/ca1.pem" "$tmp/ca2.pem" > "$tmp/bundle.pem"
    plain_hash=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" version | sed -n "s/^Image hash: //p")
    ver=$(SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CA_BUNDLE="$tmp/bundle.pem" "$1" version)
    echo "$ver" | grep -q "^CA bundle: $tmp/bundle.pem (2 certificate(s))"
    ca_hash=$(echo "$ver" | sed -n "s/^Image hash: //p")
    if [ "$ca_hash" = "$plain_hash" ]; then
        echo "image hash must change when a CA bundle is configured" >&2
        exit 1
    fi
    IMG="sagent-sandbox:$ca_hash"
    trap "rm -rf \"$tmp\"; \"$ENGINE\" rmi -f \"$IMG\" >/dev/null 2>&1 || true" EXIT
    if ! SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CA_BUNDLE="$tmp/bundle.pem" "$1" --build >"$tmp/build.log" 2>&1; then
        tail -40 "$tmp/build.log" >&2
        exit 1
    fi
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v "$(cd "$tmp" && pwd -P):/t31:ro" --security-opt label=disable "$IMG" bash -c "
        set -e
        [ \"\$SSL_CERT_FILE\" = /etc/ssl/certs/ca-certificates.crt ]
        [ \"\$NODE_EXTRA_CA_CERTS\" = /usr/local/share/sagent-ca-bundle.pem ]
        # both bundle members are in the system store
        openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /t31/ca1.pem >/dev/null
        openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /t31/ca2.pem >/dev/null
        # a server certificate issued by CA 2 is trusted end to end
        openssl req -newkey rsa:2048 -nodes -subj /CN=localhost \
            -keyout /tmp/leaf.key -out /tmp/leaf.csr >/dev/null 2>&1
        printf \"subjectAltName=DNS:localhost\n\" > /tmp/leaf.ext
        openssl x509 -req -in /tmp/leaf.csr -CA /t31/ca2.pem -CAkey /t31/ca2.key \
            -CAserial /tmp/ca.srl -CAcreateserial -days 1 -extfile /tmp/leaf.ext \
            -out /tmp/leaf.pem >/dev/null 2>&1
        openssl s_server -accept 8443 -cert /tmp/leaf.pem -key /tmp/leaf.key -www >/dev/null 2>&1 &
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if curl -fsS --max-time 2 https://localhost:8443/ >/dev/null 2>&1; then break; fi
            sleep 1
        done
        curl -fsS https://localhost:8443/ >/dev/null
        python3 -c \"import urllib.request; urllib.request.urlopen(\\\"https://localhost:8443/\\\", timeout=5)\"
        node -e \"require(\\\"https\\\").get(\\\"https://localhost:8443/\\\", r => process.exit(r.statusCode === 200 ? 0 : 1)).on(\\\"error\\\", e => { console.error(e); process.exit(1) })\"
    "
' _ "$SCLAUDE"

# ── T32: generated Dockerfile and build-failure guidance ─────────────
# A stub engine records the build context and fails the build, so this checks
# (without a real build) that the CA block is emitted only when a bundle is
# configured, that the bundle is split one-certificate-per-file in the
# context, and that a failed build prints the proxy-CA guidance.
run_test "T32: Dockerfile generation and build guidance" bash -ec '
    set -e
    tmp=$(mktemp -d /tmp/sagent-t32.XXXXXX)
    trap "rm -rf \"$tmp\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) exit 0 ;;
    version) printf "Client: Docker Engine\nServer: Docker Engine\n"; exit 0 ;;
    build)
        for last; do :; done
        cp "\$last/Dockerfile" "$tmp/Dockerfile"
        (cd "\$last" && find . -type f | sort) > "$tmp/context.txt"
        exit 1 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/fake-engine"

    if "$1" --build >"$tmp/out" 2>&1; then
        echo "build should have failed with the stub engine" >&2
        exit 1
    fi
    grep -q "sandbox image build failed" "$tmp/out"
    grep -q "point SAGENT_CA_BUNDLE at it" "$tmp/out"
    if grep -q "sagent-ca" "$tmp/Dockerfile"; then
        echo "CA block emitted without SAGENT_CA_BUNDLE" >&2
        exit 1
    fi
    grep -q "apt-get install -y gh" "$tmp/Dockerfile"
    [ "$(cat "$tmp/context.txt")" = "./Dockerfile" ]

    for n in 1 2 3; do
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=sagent-t32-ca$n" \
            -keyout "$tmp/ca$n.key" -out "$tmp/ca$n.pem" >/dev/null 2>&1
    done
    cat "$tmp/ca1.pem" "$tmp/ca2.pem" "$tmp/ca3.pem" > "$tmp/bundle.pem"
    if SAGENT_CA_BUNDLE="$tmp/bundle.pem" "$1" --build >"$tmp/out" 2>&1; then
        echo "build should have failed with the stub engine" >&2
        exit 1
    fi
    grep -q "Baking 3 CA certificate(s)" "$tmp/out"
    grep -q "(3 certificate(s)) was baked in" "$tmp/out"
    # the CA block precedes the first HTTPS fetch (the gh keyring download)
    ca_line=$(grep -n "^COPY sagent-ca/" "$tmp/Dockerfile" | cut -d: -f1)
    gh_line=$(grep -n "cli.github.com" "$tmp/Dockerfile" | head -1 | cut -d: -f1)
    [ "$ca_line" -lt "$gh_line" ]
    grep -q "^RUN update-ca-certificates" "$tmp/Dockerfile"
    grep -q "^ENV NODE_EXTRA_CA_CERTS=/usr/local/share/sagent-ca-bundle.pem" "$tmp/Dockerfile"
    printf "%s\n" ./Dockerfile ./sagent-ca-bundle.pem ./sagent-ca/sagent-001.crt ./sagent-ca/sagent-002.crt ./sagent-ca/sagent-003.crt \
        | diff - "$tmp/context.txt"
' _ "$SCLAUDE"

# ── T33: Rancher Desktop unshared workspace is refused ───────────────
# #74: Rancher Desktop shares only $HOME (and /tmp/rancher-desktop) with its
# VM, so any other workspace mounts empty. A stub engine reporting the
# rancher-desktop docker context stands in for it.
run_test "T33: Rancher Desktop unshared workspace refused" bash -ec '
    tmp=$(mktemp -d /tmp/sagent-t33.XXXXXX)
    home_ws="$HOME/.sagent-t33-ws"
    mkdir -p "$home_ws"
    trap "rm -rf \"$tmp\" \"$home_ws\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) exit 0 ;;
    version) printf "Client: Docker Engine\nServer: Docker Engine\n"; exit 0 ;;
    context) echo rancher-desktop; exit 0 ;;
    image) exit 0 ;;
    volume) exit 0 ;;
    run) echo "STUB-RUN \$*"; exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/fake-engine"
    # /tmp is outside the shared set: refused before any container starts.
    if (cd "$tmp" && "$1" --help >"$tmp/out" 2>"$tmp/err"); then
        echo "a workspace outside \$HOME should have been refused" >&2
        exit 1
    fi
    grep -q "Rancher Desktop shares only" "$tmp/err"
    if grep -q "STUB-RUN.*--help" "$tmp/out"; then
        echo "the tool container was started despite the refusal" >&2
        exit 1
    fi
    # The documented override lets it through.
    (cd "$tmp" && SAGENT_SKIP_SHARE_CHECK=1 "$1" --help) | grep -q "STUB-RUN.*--help"
    # A workspace under $HOME is fine.
    (cd "$home_ws" && "$1" --help) | grep -q "STUB-RUN.*--help"
' _ "$SCLAUDE"

# ── T34: docker CLI on a rootless daemon is refused ──────────────────
# #75: the docker CLI cannot request podman's keep-id mapping, so on a
# rootless daemon the workspace would be unusable; the wrapper must say so
# before touching anything. A stub engine reports a rootless podman server.
run_test "T34: docker CLI on rootless daemon refused" bash -ec '
    tmp=$(mktemp -d /tmp/sagent-t34.XXXXXX)
    trap "rm -rf \"$tmp\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) [ "\${2:-}" = "--format" ] && echo "name=seccomp,profile=default,name=rootless"; exit 0 ;;
    version) printf "Client: Docker Engine\nServer:\n Podman Engine:\n"; exit 0 ;;
    *) echo "STUB-CALLED \$*"; exit 0 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/fake-engine"
    if "$1" --help >"$tmp/out" 2>"$tmp/err"; then
        echo "docker CLI on a rootless daemon should have been refused" >&2
        exit 1
    fi
    grep -q "rootless podman daemon" "$tmp/err"
    grep -q "SAGENT_CONTAINER_ENGINE=podman" "$tmp/err"
    if grep -q "STUB-CALLED" "$tmp/out"; then
        echo "engine was invoked (image build, volumes or run) despite the refusal" >&2
        exit 1
    fi
    # Management commands still work against such an engine.
    "$1" version | grep -q "rootless: true"
' _ "$SCLAUDE"

print_results
