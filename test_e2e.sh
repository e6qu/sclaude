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
    for vol in sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-share sagent-apt-cache sagent-apt-lists sagent-containers; do
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
    for vol in sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-share sagent-apt-cache sagent-apt-lists sagent-containers; do
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

# ── T10b: a CLI release rebuilds one layer, not the image ────────────
# The agent CLIs are the last layer, behind AGENT_CLI_REFRESH, so `update`
# reinstalls them from a cached image. A stubbed registry lookup makes the
# CLIs look outdated; the run must take the cached path (not the no-cache
# rebuild that --force-rebuild asks for) and still leave working CLIs.
run_test "T10b: update refreshes the CLIs from cache" bash -ec '
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT
    sed "s|^fetch_npm_latest() {|fetch_npm_latest() { printf 9.9.9; return 0; }\nfetch_npm_latest_unused() {|" "$1" > "$tmpdir/sclaude"
    chmod +x "$tmpdir/sclaude"
    rc=0
    output=$(SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_SKIP_SELF_UPDATE=1 "$tmpdir/sclaude" update 2>&1) || rc=$?
    echo "$output"
    [ "$rc" -eq 0 ]
    echo "$output" | grep -q "\-> 9.9.9"
    echo "$output" | grep -q "Building shared sandbox image"
    if echo "$output" | grep -q "Updating shared sandbox image"; then
        echo "T10b: took the no-cache path for a CLI-only refresh" >&2
        exit 1
    fi
    "$ENGINE" run --rm "$SUITE_IMG" claude --version >/dev/null
    "$ENGINE" run --rm "$SUITE_IMG" codex --version >/dev/null
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
run_test "T13: volumes report (no literal -e)" bash -ec '
    OUTPUT=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" volumes 2>&1)
    if echo "$OUTPUT" | grep -q "^-e"; then
        echo "Found literal -e in output" >&2
        exit 1
    fi
    # The disk usage report lists the current image, every volume with a
    # size or state, and the caches total.
    echo "$OUTPUT" | grep -q "^  ${SUITE_IMG#*:} .* current"
    for vol in sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-share sagent-apt-cache sagent-apt-lists sagent-containers; do
        echo "$OUTPUT" | grep -qE "^  $vol +([0-9.]+[kMGT]?B|n/a|\(not created\))"
    done
    echo "$OUTPUT" | grep -q "^Volumes total: .*; caches: "
    echo "$OUTPUT" | grep -q "reset-caches"
' _ "$SCLAUDE"

# ── T14: zsh invocation ──────────────────────────────────────────────
if command -v zsh >/dev/null 2>&1; then
    run_test "T14: zsh invocation" bash -ec 'SAGENT_SKIP_RELEASE_CHECK=1 zsh "$1" version && SAGENT_SKIP_RELEASE_CHECK=1 zsh "$2" version' _ "$SCLAUDE" "$SCODEX"
else
    skip_test "T14: zsh invocation" "zsh not installed"
fi

# ── T15: temp file cleanup on build failure ───────────────────────────
run_test "T15: no leaked temp files" bash -ec '
    # A private TMPDIR for the wrapper (mktemp honors it), so nothing else on
    # the machine can write into the directory under test.
    PRIVATE_TMP=$(mktemp -d)
    trap "rm -rf \"$PRIVATE_TMP\"" EXIT
    TMPDIR="$PRIVATE_TMP" SAGENT_SKIP_RELEASE_CHECK=1 "$1" --build >/dev/null 2>&1 || true
    LEAKED=$(find "$PRIVATE_TMP" -mindepth 1 | wc -l)
    if [ "$LEAKED" -gt 0 ]; then
        echo "Temp files leaked:" >&2
        find "$PRIVATE_TMP" -mindepth 1 >&2
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
run_test "T19: image has both CLIs, gh, and the configured toolchains" bash -ec '
    IMG="$SUITE_IMG"
    if ! "$ENGINE" image inspect "$IMG" >/dev/null 2>&1; then
        echo "No sagent image found" >&2
        exit 1
    fi
    "$ENGINE" run --rm "$IMG" claude --version >/dev/null
    "$ENGINE" run --rm "$IMG" codex --version >/dev/null
    "$ENGINE" run --rm "$IMG" gh --version | grep -q "^gh version"
    # Toolchain versions come from the wrapper so the test never hard-codes
    # the defaults.
    tc=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" version | sed -n "s/^Toolchain: //p")
    node=$(echo "$tc" | sed "s/.*node=\([^ ]*\).*/\1/")
    python=$(echo "$tc" | sed "s/.*python=\([^ ]*\).*/\1/")
    go=$(echo "$tc" | sed "s/.*go=\([^ ]*\).*/\1/")
    rust=$(echo "$tc" | sed "s/.*rust=\([^ ]*\).*/\1/")
    java=$(echo "$tc" | sed "s/.*java=\([^ ]*\).*/\1/")
    ubuntu=$(echo "$tc" | sed "s/.*ubuntu=\([^ ]*\).*/\1/")
    tools=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" version | sed -n "s/^Tools: //p")
    "$ENGINE" run --rm "$IMG" bash -ec "
        grep -q \"VERSION_ID=\\\"$ubuntu\\\"\" /etc/os-release
        node --version | grep -q \"^v$node\\.\"
        python3 --version | grep -q \"^Python $python\\.\"
        pip3 --version | grep -q \"(python $python)\"
        uv --version >/dev/null
        [ \"$go\" = none ] || go version | grep -q \"go$go\"
        [ \"$rust\" = none ] || { cargo --version >/dev/null && rustfmt --version >/dev/null && cargo clippy --version >/dev/null; }
        [ \"$java\" = none ] || { java -version 2>&1 | grep -q \"version \\\"$java\\.\"; [ -n \"\$JAVA_HOME\" ]; }
        podman --version >/dev/null && command -v pasta >/dev/null
        # Everyday utilities
        for u in tree htop btop top jq rg fd bat vim nano wget zip unzip rsync ssh file lsof ip dig nc tmux sqlite3 less; do
            command -v \$u >/dev/null || { echo \"utility missing: \$u\" >&2; exit 1; }
        done
        # Every selected tool is present; every unselected one is absent.
        for tool in typescript tsx bun corepack create-next-app create-vite shadcn maven gradle quarkus spring; do
            case \" $tools \" in *\" \$tool \"*) want=1 ;; *) want=0 ;; esac
            case \$tool in
                typescript) cmd=tsc ;; corepack) cmd=yarn ;; maven) cmd=mvn ;; *) cmd=\$tool ;;
            esac
            if [ \$want = 1 ]; then
                case \$tool in
                    typescript) tsc --version | grep -q \"^Version\" ;;
                    corepack) corepack --version >/dev/null && command -v yarn >/dev/null && command -v pnpm >/dev/null ;;
                    maven) mvn -v | grep -q \"^Apache Maven\" ;;
                    gradle) gradle --version | grep -q \"^Gradle\" ;;
                    spring) spring --version | grep -q \"^Spring CLI\" ;;
                    create-vite) command -v create-vite >/dev/null ;;
                    *) \$tool --version >/dev/null ;;
                esac
            elif command -v \$cmd >/dev/null; then
                echo \"\$tool is not selected but \$cmd is in the image\" >&2; exit 1
            fi
        done
    "
' _ "$SCLAUDE"

# ── T19b: clipboard shims, git defaults and locale in the image ──────
run_test "T19b: image clipboard shims, git defaults, locale" bash -ec '
    "$ENGINE" run --rm -i "$SUITE_IMG" bash -s <<"EOF"
set -e
[ "$LANG" = C.UTF-8 ]
for n in pbcopy pbpaste wl-copy wl-paste xclip xsel; do
    [ "$(readlink -f "$(command -v $n)")" = /usr/local/bin/host-clipboard ] || { echo "$n is not the clipboard shim" >&2; exit 1; }
done
# Copy emits OSC 52 with the base64 payload, ESC-backslash terminated (to stderr without a tty).
out=$(printf hello | pbcopy 2>&1)
[ "$out" = "$(printf "\033]52;c;aGVsbG8=\033\\\\")" ]
printf hello | xclip -selection clipboard 2>&1 | grep -q "52;c;aGVsbG8="
# Without the bridge, reads fail loudly and print nothing on stdout.
for c in pbpaste wl-paste "xclip -selection clipboard -t TARGETS -o" "xsel --clipboard --output"; do
    out=$($c 2>/dev/null) && { echo "$c should fail" >&2; exit 1; }
    [ -z "$out" ]
    $c 2>&1 | grep -q "no clipboard bridge"
done
[ "$(git config --system --get credential.https://github.com.helper)" = "!gh auth git-credential" ]
! git config --system --get-all url.https://github.com/.insteadof
git lfs version | grep -q "^git-lfs/"
[ "$(git config --system --get filter.lfs.required)" = true ]
EOF
' _ "$SCLAUDE"

# ── T19c: clipboard bridge round trip ────────────────────────────────
# The wrapper's clipboard agent (host side, sourced from the wrapper) serves
# the sandbox's clipboard shims through a bind-mounted directory. A fake
# host clipboard (pbcopy/pbpaste/osascript on macOS, xclip under DISPLAY on
# Linux) records what the agent does, so this runs on headless CI too.
run_test "T19c: clipboard bridge round trip" bash -ec '
    TMP=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t19c.XXXXXX")
    AGENT=""
    trap "kill \$AGENT 2>/dev/null || true; rm -rf \"$TMP\"" EXIT
    mkdir -p "$TMP/bin" "$TMP/bridge"
    printf "png-bytes" > "$TMP/image.png"
    cat > "$TMP/bin/pbcopy" <<EOF
#!/bin/sh
cat > "$TMP/clip.txt"
EOF
    cat > "$TMP/bin/pbpaste" <<EOF
#!/bin/sh
cat "$TMP/clip.txt"
EOF
    cat > "$TMP/bin/osascript" <<EOF
#!/bin/sh
case "\$*" in
    *"clipboard info"*) echo "«class PNGf», 9, string, 4" ;;
    *PNGf*) out=\$(printf "%s\\n" "\$@" | sed -n "s/.*POSIX file \"\\(.*\\)\" with.*/\\1/p"); cp "$TMP/image.png" "\$out" ;;
esac
EOF
    cat > "$TMP/bin/xclip" <<EOF
#!/bin/sh
target=UTF8_STRING; out=0
while [ \$# -gt 0 ]; do case "\$1" in -t) target=\$2; shift ;; -o) out=1 ;; esac; shift; done
if [ \$out = 0 ]; then cat > "$TMP/clip.txt"; exit 0; fi
case "\$target" in
    TARGETS) printf "TARGETS\\nimage/png\\ntext/plain\\n" ;;
    image/png) cat "$TMP/image.png" ;;
    *) cat "$TMP/clip.txt" ;;
esac
EOF
    chmod +x "$TMP"/bin/*
    export PATH="$TMP/bin:$PATH" DISPLAY=:9
    unset WAYLAND_DISPLAY
    printf "from-host" > "$TMP/clip.txt"
    # The agent, straight from the wrapper.
    sed -n "/^# ---- Clipboard bridge/,/^# ---- End clipboard bridge/p" "$1" > "$TMP/bridge.sh"
    bash -c ". \"$TMP/bridge.sh\"; clipboard_bridge_serve \"$TMP/bridge\"" &
    AGENT=$!
    BRIDGE_HOST=$(cd "$TMP/bridge" && pwd -P)
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v "$BRIDGE_HOST:/run/sagent/clipboard:rw" "$SUITE_IMG" bash -ec "
        [ \"\$(pbpaste)\" = from-host ]
        [ \"\$(wl-paste --no-newline)\" = from-host ]
        [ \"\$(xclip -selection clipboard -o)\" = from-host ]
        xclip -selection clipboard -t TARGETS -o | grep -q image/png
        wl-paste -l | grep -q image/png
        [ \"\$(xclip -selection clipboard -t image/png -o)\" = png-bytes ]
        [ \"\$(wl-paste --type image/png)\" = png-bytes ]
        ! xclip -selection clipboard -t image/bmp -o 2>/dev/null
        printf to-host | pbcopy
        printf to-host-2 | wl-copy
        printf to-host-3 | xclip -selection clipboard
        printf to-host-4 | xsel --clipboard --input
        [ \"\$(ls -A /run/sagent/clipboard)\" = \"\" ]
    "
    [ "$(cat "$TMP/clip.txt")" = to-host-4 ]
    # A request nobody answers fails loudly instead of hanging.
    kill "$AGENT"; wait "$AGENT" 2>/dev/null || true
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v "$BRIDGE_HOST:/run/sagent/clipboard:rw" "$SUITE_IMG" bash -ec "
        ! pbpaste 2>\"/tmp/err\"
        grep -q \"did not answer\" /tmp/err
    "
' _ "$SCLAUDE"

# ── T20a: host git config, gh login and SSH sync ─────────────────────
# The wrapper carries the host's global git config (minus host-only keys)
# and gh login into the home volume on every run. GIT_CONFIG_GLOBAL and
# GH_CONFIG_DIR point git and a fake gh at synthetic state; XDG_CONFIG_HOME
# stays untouched because the wrapper's own config file lives there and CI
# slims the image through it. The volume is inspected as root: on rootless
# podman the image's user maps to a subordinate UID and cannot read the
# 600-mode hosts.yml.
run_test "T20a: host git config, gh login and SSH sync" bash -ec '
    TMP=$(mktemp -d)
    trap "rm -rf \"$TMP\"" EXIT
    mkdir -p "$TMP/bin" "$TMP/gh"
    printf "*.swp\n" > "$TMP/ignore"
    cat > "$TMP/gitconfig" <<EOF
[user]
	name = Sync Test
	email = sync@example.com
	signingkey = ABCDEF
[commit]
	gpgsign = true
[credential]
	helper = osxkeychain
[core]
	editor = code --wait
	excludesfile = $TMP/ignore
[alias]
	st = status --short
[safe]
	directory = /a
	directory = /b
EOF
    cat > "$TMP/gh/hosts.yml" <<EOF
github.com:
    git_protocol: ssh
    user: alice
ghe.example.com:
    user: bob
EOF
    cat > "$TMP/bin/gh" <<EOF
#!/bin/sh
[ -n "\${GH_TOKEN:-}" ] && { echo LEAKED_ENV_TOKEN; exit 0; }
case "\$4" in
    github.com) echo gho_synctest ;;
    ghe.example.com) echo ghp_ghetoken ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TMP/bin/gh"
    PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GH_CONFIG_DIR="$TMP/gh" GH_TOKEN=envtoken \
        SAGENT_GIT_PROTOCOL=https SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo --help >/dev/null
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        cfg=/h/.config/git/config
        [ \"\$(git config --file \$cfg --get user.name)\" = \"Sync Test\" ]
        [ \"\$(git config --file \$cfg --get alias.st)\" = \"status --short\" ]
        [ \"\$(git config --file \$cfg --get-all safe.directory | wc -l)\" -eq 2 ]
        for k in user.signingkey commit.gpgsign credential.helper core.editor core.excludesfile; do
            if git config --file \$cfg --get \$k >/dev/null; then echo \"host-only key synced: \$k\" >&2; exit 1; fi
        done
        [ \"\$(git config --file \$cfg --get credential.https://ghe.example.com.helper)\" = \"!gh auth git-credential\" ]
        git config --file \$cfg --get-all url.https://ghe.example.com/.insteadof | grep -qx \"git@ghe.example.com:\"
        git config --file \$cfg --get-all url.https://github.com/.insteadof | grep -qx \"ssh://git@github.com/\"
        [ ! -e /h/.ssh/.sagent-synced ]
        grep -qx \"*.swp\" /h/.config/git/ignore
        [ -e /h/.gitconfig ]
        grep -q gho_synctest /h/.config/gh/hosts.yml
        grep -q ghp_ghetoken /h/.config/gh/hosts.yml
        grep -q \"user: alice\" /h/.config/gh/hosts.yml
        grep -q \"git_protocol: https\" /h/.config/gh/hosts.yml
        ! grep -q LEAKED_ENV_TOKEN /h/.config/gh/hosts.yml
        [ \"\$(stat -c %a /h/.config/gh/hosts.yml)\" = 600 ]
    "
    # The synced git files mirror the host: gone from the host, gone from the
    # volume. An excludes file that no longer exists stands in for "none"
    # (the default ~/.config/git/ignore may exist on the machine running this).
    # Unset, the protocol follows the host gh (ssh in this hosts.yml): no
    # rewrite, and ~/.ssh is synced by manifest with a sandbox-made key left
    # alone. Back on https the manifest'"'"'s files go and that key stays.
    printf "[core]\n\texcludesfile = %s\n" "$TMP/missing" > "$TMP/gitconfig2"
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        mkdir -p /h/.ssh && echo sandbox-key > /h/.ssh/id_sandbox
    "
    # The sync mirrors ~/.ssh only when it exists; a CI runner may have none.
    if [ ! -d ~/.ssh ]; then mkdir -m 700 ~/.ssh; fi
    PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig2" GH_CONFIG_DIR="$TMP/gh" \
        SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo --help >/dev/null
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        ! git config --file /h/.config/git/config --get user.name
        [ ! -e /h/.config/git/ignore ]
        grep -q \"git_protocol: ssh\" /h/.config/gh/hosts.yml
        ! git config --file /h/.config/git/config --get-all url.https://github.com/.insteadof
        [ -f /h/.ssh/.sagent-synced ]
        [ \"\$(stat -c %a /h/.ssh)\" = 700 ]
        while IFS= read -r f; do
            [ -f \"/h/.ssh/\$f\" ] && [ \"\$(stat -c %a \"/h/.ssh/\$f\")\" = 600 ] || { echo \"synced ssh file wrong: \$f\" >&2; exit 1; }
        done < /h/.ssh/.sagent-synced
        [ -f /h/.ssh/id_sandbox ]
    "
    PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig2" GH_CONFIG_DIR="$TMP/gh" \
        SAGENT_GIT_PROTOCOL=https SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo --help >/dev/null
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        [ ! -e /h/.ssh/.sagent-synced ]
        [ -f /h/.ssh/id_sandbox ]
        [ \"\$(ls -A /h/.ssh | wc -l)\" -eq 1 ]
        rm -f /h/.ssh/id_sandbox
    "
' _ "$SCLAUDE"

# ── T20c: an identity git only has in the workspace is synced ────────
# A repo-local identity (or one from a conditional include) is what git
# commits as here, but a read of the global config alone never sees it, and
# without it commits in the sandbox have no author.
run_test "T20c: workspace git identity syncs" bash -ec '
    TMP=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t20c.XXXXXX")
    trap "rm -rf \"$TMP\"" EXIT
    mkdir -p "$TMP/ws"
    printf "[push]\n\tautosetupremote = true\n" > "$TMP/gitconfig"
    git -C "$TMP/ws" init -q .
    git -C "$TMP/ws" config user.name "Repo Identity"
    git -C "$TMP/ws" config user.email repo@example.com
    # The global config alone has no identity, so this is the case the sync
    # used to miss.
    [ -z "$(GIT_CONFIG_GLOBAL="$TMP/gitconfig" git config --global --includes --get user.name || true)" ]
    (
        cd "$TMP/ws"
        GIT_CONFIG_GLOBAL="$TMP/gitconfig" SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo --help >/dev/null
    )
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        [ \"\$(git config --file /h/.config/git/config --get user.name)\" = \"Repo Identity\" ]
        [ \"\$(git config --file /h/.config/git/config --get user.email)\" = repo@example.com ]
    "
' _ "$SCLAUDE"

# ── T20b: the sync tar is quiet when the host clock is ahead ─────────
# A host clock a fraction of a second ahead of the VM the engine runs in made
# GNU tar warn about every extracted file. The extraction command is read out
# of the wrapper, so dropping the flag fails here.
run_test "T20b: sync tar quiet on clock skew" bash -ec '
    TMP=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t20b.XXXXXX")
    trap "rm -rf \"$TMP\"" EXIT
    mkdir -p "$TMP/stage/home"
    echo x > "$TMP/stage/home/f"
    future=$(date -v+1H +%Y%m%d%H%M.%S 2>/dev/null || date -d "+1 hour" +%Y%m%d%H%M.%S)
    touch -t "$future" "$TMP/stage/home/f" "$TMP/stage/home" "$TMP/stage"
    cmd=$(grep -oE "tar -x[a-z]*f - -C /tmp/sync" "$1" | head -1)
    [ -n "$cmd" ]
    tar_args=""
    if [ "$(uname -s)" = Darwin ]; then tar_args="--no-xattrs --no-mac-metadata"; fi
    # shellcheck disable=SC2086
    tar $tar_args -C "$TMP/stage" -cf - . \
        | "$ENGINE" run --rm -i "$SUITE_IMG" bash -c "mkdir -p /tmp/sync && $cmd" 2>"$TMP/err"
    if [ -s "$TMP/err" ]; then
        echo "extraction was not quiet:" >&2
        cat "$TMP/err" >&2
        exit 1
    fi
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
    divergent="read_credentials sync_state run_tool"
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
    # Claude Code sign-in (#78): the localhost callback becomes the manual-code
    # redirect, code=true is kept, everything else is untouched, a note follows.
    login="https://claude.ai/oauth/authorize?code=true&client_id=abc&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback&scope=user%3Aprofile&state=xyz"
    out=$("$ENGINE" run --rm "$IMG" xdg-open "$login" 2>&1)
    printf "%s" "$out" | grep -q "redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Aprofile&state=xyz"
    if printf "%s" "$out" | grep -q "localhost"; then echo "localhost callback left in the sign-in URL" >&2; exit 1; fi
    printf "%s" "$out" | grep -o "code=true" | grep -c . | grep -qx 2
    printf "%s" "$out" | grep -q "paste the code"
    # Other URLs are not rewritten.
    out=$("$ENGINE" run --rm "$IMG" xdg-open "https://github.com/login/device" 2>&1)
    if printf "%s" "$out" | grep -q "paste the code"; then echo "non-Claude URL got the sign-in note" >&2; exit 1; fi
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

    # CAs carry the extensions strict verifiers (Python 3.13+) insist on;
    # generated with the sandbox image'"'"'s openssl so the host'"'"'s flavor
    # (LibreSSL on macOS) does not matter.
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v "$(cd "$tmp" && pwd -P):/t31:rw" --security-opt label=disable "$SUITE_IMG" bash -ec "
        cd /t31
        for n in 1 2; do
            openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=sagent-t31-ca\$n \
                -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
                -keyout ca\$n.key -out ca\$n.pem >/dev/null 2>&1
        done
    "
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
    run) cat >/dev/null; echo TLS-OK; exit 0 ;;
    build)
        for last; do :; done
        cp "\$last/Dockerfile" "$tmp/Dockerfile"
        (cd "\$last" && find . -type f | sort) > "$tmp/context.txt"
        exit 1 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    # Defaults only: no user or CI config file may shape the Dockerfile this
    # test inspects.
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/fake-engine" SAGENT_CONFIG_FILE="$tmp/no-config"

    if "$1" --build >"$tmp/out" 2>&1; then
        echo "build should have failed with the stub engine" >&2
        exit 1
    fi
    grep -q "sandbox image build failed" "$tmp/out"
    grep -q "TLS interception was checked before the build" "$tmp/out"
    if grep -q "sagent-ca" "$tmp/Dockerfile"; then
        echo "CA block emitted without SAGENT_CA_BUNDLE" >&2
        exit 1
    fi
    grep -q "apt-get install -y gh" "$tmp/Dockerfile"
    [ "$(cat "$tmp/context.txt")" = "./Dockerfile" ]
    # Toolchain versions reach the Dockerfile as FROM/ARG values.
    tc=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" version | sed -n "s/^Toolchain: //p")
    grep -q "^FROM ubuntu:$(echo "$tc" | sed "s/.*ubuntu=\([^ ]*\).*/\1/")\$" "$tmp/Dockerfile"
    grep -q "^ARG NODE_VERSION=$(echo "$tc" | sed "s/.*node=\([^ ]*\).*/\1/")\$" "$tmp/Dockerfile"
    grep -q "go.dev/dl" "$tmp/Dockerfile"
    grep -q "sh.rustup.rs" "$tmp/Dockerfile"
    grep -q "api.adoptium.net" "$tmp/Dockerfile"
    # "none" leaves a toolchain out of the image entirely.
    SAGENT_GO_VERSION=none SAGENT_RUST_VERSION=none SAGENT_JAVA_VERSION=none "$1" --build >/dev/null 2>&1 || true
    if grep -qE "go.dev/dl|sh.rustup.rs|api.adoptium.net|JAVA_HOME|RUSTUP_HOME" "$tmp/Dockerfile"; then
        echo "toolchain blocks emitted despite =none" >&2
        exit 1
    fi
    grep -q "^ARG GO_VERSION=none\$" "$tmp/Dockerfile"
    # SAGENT_TOOLS=none: only the agent CLIs are installed, in their own
    # last layer; no JS tooling layer at all.
    SAGENT_TOOLS=none "$1" --build >/dev/null 2>&1 || true
    grep -q "npm install -g @anthropic-ai/claude-code @openai/codex\$" "$tmp/Dockerfile"
    if grep -qE "^RUN npm install -g " "$tmp/Dockerfile"; then
        echo "a JS tooling layer was emitted despite SAGENT_TOOLS=none" >&2
        exit 1
    fi
    if grep -qE "corepack enable|apache-maven|gradle.zip|quarkus-cli|spring-boot-cli" "$tmp/Dockerfile"; then
        echo "tooling emitted despite SAGENT_TOOLS=none" >&2
        exit 1
    fi
    # A subset: named tools and nothing else.
    SAGENT_TOOLS="bun,maven" "$1" --build >/dev/null 2>&1 || true
    # The selected JS tooling is its own layer; the agent CLIs are the last
    # one, so a CLI release does not rebuild everything after them.
    grep -q "^RUN npm install -g bun\$" "$tmp/Dockerfile"
    grep -q "npm install -g @anthropic-ai/claude-code @openai/codex\$" "$tmp/Dockerfile"
    grep -q "apache-maven" "$tmp/Dockerfile"
    if grep -qE "corepack enable|gradle.zip|quarkus-cli|spring-boot-cli" "$tmp/Dockerfile"; then
        echo "unselected tooling emitted" >&2
        exit 1
    fi

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
    grep -q "with SAGENT_CA_BUNDLE=.*(3 certificate(s))" "$tmp/out"
    # the CA block precedes the first HTTPS fetch (the gh keyring download)
    ca_line=$(grep -n "^COPY sagent-ca/" "$tmp/Dockerfile" | cut -d: -f1)
    gh_line=$(grep -n "cli.github.com" "$tmp/Dockerfile" | head -1 | cut -d: -f1)
    [ "$ca_line" -lt "$gh_line" ]
    grep -q "^RUN update-ca-certificates" "$tmp/Dockerfile"
    grep -q "^ENV NODE_EXTRA_CA_CERTS=/usr/local/share/sagent-ca-bundle.pem" "$tmp/Dockerfile"
    printf "%s\n" ./Dockerfile ./sagent-ca-bundle.pem ./sagent-ca/sagent-001.crt ./sagent-ca/sagent-002.crt ./sagent-ca/sagent-003.crt \
        | diff - "$tmp/context.txt"
' _ "$SCLAUDE"

# ── T32b: `dockerfile` prints the build's Dockerfile ─────────────────
# The release workflow builds the published images from this output, so it
# must be the Dockerfile a build would use: same content, the metadata
# stamp with the version hash, and SAGENT_IMAGE_UID/GID re-keying the hash
# to the user the image is built for.
run_test "T32b: dockerfile command" bash -ec '
    tmp=$(mktemp -d)
    trap "rm -rf \"$tmp\"" EXIT
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE="$tmp/no-config"
    "$1" dockerfile > "$tmp/Dockerfile"
    head -1 "$tmp/Dockerfile" | grep -q "^FROM ubuntu:"
    hash=$("$1" version | sed -n "s/^Image hash: //p")
    grep -q "^LABEL sagent.version=\"$hash\"" "$tmp/Dockerfile"
    tail -1 "$tmp/Dockerfile" | grep -q "^LABEL sagent.version="
    # The metadata is a label, not a layer: a RUN that writes a file would
    # make every build export and unpack the whole image again.
    ! grep -q "sagent-metadata.json" "$tmp/Dockerfile"
    # The agent CLIs are the last thing built, behind the refresh arg, so a
    # CLI release rebuilds one layer instead of everything after it.
    grep -q "^ARG AGENT_CLI_REFRESH=" "$tmp/Dockerfile"
    last_run=$(grep -n "^RUN " "$tmp/Dockerfile" | tail -1)
    case "$last_run" in *"npm install -g @anthropic-ai/claude-code @openai/codex"*) ;;
        *) echo "the agent CLI install is not the last RUN: $last_run" >&2; exit 1 ;;
    esac
    case "$last_run" in *"AGENT_CLI_REFRESH"*) ;;
        *) echo "the agent CLI layer does not use AGENT_CLI_REFRESH" >&2; exit 1 ;;
    esac
    # Another uid/gid is another image: the stamp follows.
    other=$(SAGENT_IMAGE_UID=4242 SAGENT_IMAGE_GID=4242 "$1" dockerfile | sed -n "s/^LABEL sagent.version=\"\([0-9a-f]*\)\".*/\1/p")
    [ -n "$other" ] && [ "$other" != "$hash" ]
    # Same for both wrappers (one shared image).
    diff <(grep -v build_timestamp "$tmp/Dockerfile") <("$2" dockerfile | grep -v build_timestamp)
' _ "$SCLAUDE" "$SCODEX"

# ── T33: unshared workspace on VM-backed engines is refused ──────────
# #74: Rancher Desktop and colima share only $HOME (plus one /tmp subdir)
# with their VM, so any other workspace mounts empty. A stub engine reporting
# their docker contexts stands in for them.
run_test "T33: unshared workspace refused (Rancher Desktop, colima)" bash -ec '
    tmp=$(mktemp -d /tmp/sagent-t33.XXXXXX)
    home_ws="$HOME/.sagent-t33-ws"
    mkdir -p "$home_ws"
    trap "rm -rf \"$tmp\" \"$home_ws\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) exit 0 ;;
    version) printf "Client: Docker Engine\nServer: Docker Engine\n"; exit 0 ;;
    context) cat "$tmp/context"; exit 0 ;;
    image) exit 0 ;;
    volume) exit 0 ;;
    run) echo "STUB-RUN \$*"; exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/fake-engine"
    for ctx in rancher-desktop colima colima-work; do
        echo "$ctx" > "$tmp/context"
        # /tmp is outside the shared set: refused before any container starts.
        if (cd "$tmp" && "$1" --help >"$tmp/out" 2>"$tmp/err"); then
            echo "$ctx: a workspace outside \$HOME should have been refused" >&2
            exit 1
        fi
        grep -q "shares only" "$tmp/err"
        grep -q "SAGENT_SKIP_SHARE_CHECK=1" "$tmp/err"
        if grep -q "STUB-RUN.*--help" "$tmp/out"; then
            echo "$ctx: the tool container was started despite the refusal" >&2
            exit 1
        fi
        # The documented override lets it through.
        (cd "$tmp" && SAGENT_SKIP_SHARE_CHECK=1 "$1" --help) | grep -q "STUB-RUN.*--help"
        # A workspace under $HOME is fine.
        (cd "$home_ws" && "$1" --help) | grep -q "STUB-RUN.*--help"
    done
    # Other contexts (Docker Desktop shares /tmp) are not checked.
    echo desktop-linux > "$tmp/context"
    (cd "$tmp" && "$1" --help) | grep -q "STUB-RUN.*--help"
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

# ── T35: toolchain version settings ──────────────────────────────────
# Versions are validated up front and are part of the image hash, so a
# different toolchain is a different image.
run_test "T35: toolchain version settings validated and hashed" bash -ec '
    # Defaults only (no user or CI config file) until the config subtest below.
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE=/nonexistent/sagent-config
    base=$("$1" version | sed -n "s/^Image hash: //p")
    for bad in "SAGENT_UBUNTU_VERSION=noble" "SAGENT_NODE_VERSION=v26" "SAGENT_PYTHON_VERSION=3" "SAGENT_GO_VERSION=go1.27" "SAGENT_RUST_VERSION=latest" "SAGENT_JAVA_VERSION=26.0"; do
        if env "$bad" "$1" version >/dev/null 2>/tmp/t35-err; then
            echo "$bad should have been rejected" >&2
            exit 1
        fi
        grep -q "is not valid; expected" /tmp/t35-err
    done
    rm -f /tmp/t35-err
    for good in "SAGENT_UBUNTU_VERSION=24.04" "SAGENT_NODE_VERSION=24" "SAGENT_PYTHON_VERSION=3.13" "SAGENT_GO_VERSION=none" "SAGENT_RUST_VERSION=1.98.0" "SAGENT_JAVA_VERSION=none"; do
        h=$(env "$good" "$1" version | sed -n "s/^Image hash: //p")
        if [ "$h" = "$base" ]; then
            echo "$good must change the image hash" >&2
            exit 1
        fi
        # SAGENT_UBUNTU_VERSION=24.04 shows up as "ubuntu=24.04"
        key=$(echo "${good%%=*}" | sed "s/^SAGENT_//; s/_VERSION//" | tr "[:upper:]" "[:lower:]")
        env "$good" "$1" version | grep -q "^Toolchain: .*$key=${good#*=}"
    done
    # Config file values apply, environment wins over them.
    cfg=$(mktemp -d /tmp/sagent-t35.XXXXXX)
    trap "rm -rf \"$cfg\"" EXIT
    printf "SAGENT_NODE_VERSION=\"22\"\n" > "$cfg/config"
    SAGENT_CONFIG_FILE="$cfg/config" "$1" version | grep -q "^Toolchain: .*node=22 "
    SAGENT_CONFIG_FILE="$cfg/config" SAGENT_NODE_VERSION=24 "$1" version | grep -q "^Toolchain: .*node=24 "
' _ "$SCLAUDE"

# ── T36: cache volumes are cleared when their toolchain changes ───────
# The pip volume carries a stamp of the Python it was filled for; contents
# for another version are cleared automatically on the next run, with a
# warning, so upgrades never need a manual reset.
run_test "T36: stale toolchain caches cleared automatically" bash -ec '
    IMG="$SUITE_IMG"
    "$ENGINE" volume rm sagent-pip >/dev/null 2>&1 || true
    "$ENGINE" volume create sagent-pip >/dev/null
    "$ENGINE" run --rm $SAGENT_TEST_USERNS --user root -v sagent-pip:/v "$IMG" bash -c "
        mkdir -p /v/lib/python3.9/site-packages && echo old > /v/lib/python3.9/site-packages/old.py
        echo python=3.9 > /v/.sagent-stamp
    "
    out=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" --help 2>&1 >/dev/null || true)
    echo "$out" | grep -q "Sandbox Python changed (python=3.9 -> python="
    py=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" version | sed -n "s/.*python=\([^ ]*\).*/\1/p")
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v sagent-pip:/v "$IMG" bash -ec "
        [ ! -e /v/lib ]
        [ \"\$(cat /v/.sagent-stamp)\" = python=$py ]
    "
    # A second run with the same toolchain leaves the volume alone (and is quiet).
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v sagent-pip:/v "$IMG" bash -c "echo keep > /v/keep"
    out=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" --help 2>&1 >/dev/null || true)
    if echo "$out" | grep -q "changed ("; then
        echo "unchanged toolchain must not clear caches" >&2
        exit 1
    fi
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v sagent-pip:/v "$IMG" test -f /v/keep
' _ "$SCLAUDE"

# ── T37: reset-caches keeps credentials, config and home ─────────────
run_test "T37: reset-caches clears only cache volumes" bash -ec '
    for vol in sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-share sagent-apt-cache sagent-apt-lists sagent-containers; do
        "$ENGINE" volume create "$vol" >/dev/null 2>&1 || true
    done
    SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_ASSUME_YES=1 "$1" reset-caches
    for vol in sagent-npm sagent-pip sagent-apt-cache sagent-apt-lists sagent-containers; do
        if "$ENGINE" volume inspect "$vol" >/dev/null 2>&1; then
            echo "cache volume $vol survived reset-caches" >&2
            exit 1
        fi
    done
    # sagent-share holds tools someone installed (uv), not a cache.
    for vol in sclaude-config scodex-config sagent-rootfs sagent-share; do
        "$ENGINE" volume inspect "$vol" >/dev/null
    done
' _ "$SCLAUDE"

# ── T37b: ~/.local/share is its own volume, migrated in place ────────
# uv installs tools and its managed Pythons under ~/.local/share, which used
# to sit in the pip volume and was wiped whenever the image Python changed.
# An existing install must not have to do anything but run again.
run_test "T37b: share volume, migrated from the pip volume" bash -ec '
    # Its own workspace: `shell` attaches to a sandbox already running for a
    # directory, and an attached shell runs no sync, so the migration under
    # test would never happen.
    WS=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t37b.XXXXXX")
    trap "rm -rf \"$WS\"" EXIT
    cd "$WS"
    "$ENGINE" volume rm sagent-share >/dev/null 2>&1 || true
    "$ENGINE" volume create sagent-pip >/dev/null 2>&1 || true
    "$ENGINE" run --rm --user root -v sagent-pip:/p "$SUITE_IMG" bash -ec "
        mkdir -p /p/share/uv/tools/marker && echo carried > /p/share/uv/tools/marker/f
    "
    rc=0
    out=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" shell -c "cat ~/.local/share/uv/tools/marker/f" 2>&1) || rc=$?
    if ! echo "$out" | grep -q "^carried$" || ! echo "$out" | grep -q "Moving ~/.local/share"; then
        echo "the marker staged in the pip volume did not move into the share volume (run exited $rc); the run said:" >&2
        echo "$out" >&2
        echo "volumes:" >&2
        "$ENGINE" volume ls --format "{{.Name}}" | grep -E "^sagent-|^sclaude-" >&2 || true
        exit 1
    fi
    # The volume mounts on a directory the image owns, so the sandbox user
    # can write there even when nothing repaired the ownership.
    "$ENGINE" run --rm "$SUITE_IMG" bash -ec "
        [ \"\$(stat -c %U /home/agent/.local/share)\" = agent ]
        [ \"\$(stat -c %U /home/agent/.local/bin)\" = agent ]
        [ \"\$(stat -c %U /home/agent/.npm-global)\" = agent ]
    "
    # A tool installed with uv is there on the next run. --force so a leftover
    # executable from an earlier run is replaced instead of refused.
    if ! install=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" shell -c "uv tool install --force --quiet cowsay" 2>&1); then
        echo "uv tool install failed:" >&2
        echo "$install" >&2
        exit 1
    fi
    SAGENT_SKIP_RELEASE_CHECK=1 "$1" shell -c "uv tool list" 2>/dev/null | grep -q cowsay
' _ "$SCLAUDE"

# ── T38: tools and config commands edit the text config ──────────────
run_test "T38: tools/config commands" bash -ec '
    cfg=$(mktemp -d /tmp/sagent-t38.XXXXXX)
    trap "rm -rf \"$cfg\"" EXIT
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE="$cfg/config"
    base=$("$1" version | sed -n "s/^Image hash: //p")
    "$1" tools | grep -qE "^  bun +js +included"
    "$1" tools disable bun gradle 2>/dev/null
    grep -qx "SAGENT_TOOLS=\"typescript,tsx,corepack,create-next-app,create-vite,shadcn,maven,quarkus,spring\"" "$cfg/config"
    "$1" tools | grep -qE "^  bun +js +excluded"
    "$1" version | grep -q "^Tools: typescript tsx corepack create-next-app create-vite shadcn maven quarkus spring$"
    [ "$("$1" version | sed -n "s/^Image hash: //p")" != "$base" ]
    "$1" tools enable java 2>/dev/null
    "$1" version | grep -q "^Tools: .* maven gradle quarkus spring$"
    "$1" tools disable all 2>/dev/null
    "$1" version | grep -q "^Tools: none$"
    if "$1" tools enable no-such-tool >/dev/null 2>&1; then echo "unknown tool accepted" >&2; exit 1; fi
    # config: set, get, list, unset, validation, unknown keys
    "$1" config set SAGENT_NODE_VERSION 24 2>/dev/null
    "$1" config set MEMORY_LIMIT 8g 2>/dev/null
    [ "$("$1" config get SAGENT_NODE_VERSION)" = 24 ]
    "$1" config list | grep -qE "^  SAGENT_NODE_VERSION +24 +config$"
    "$1" config list | grep -qE "^  MEMORY_LIMIT +8g +config$"
    "$1" version | grep -q "^Toolchain: .*node=24 "
    "$1" version | grep -q "^Limits: memory=8g "
    if "$1" config set SAGENT_NODE_VERSION v24 >/dev/null 2>&1; then echo "invalid value accepted" >&2; exit 1; fi
    if "$1" config set NOT_A_SETTING 1 >/dev/null 2>&1; then echo "unknown key accepted" >&2; exit 1; fi
    "$1" config unset MEMORY_LIMIT 2>/dev/null
    if grep -q MEMORY_LIMIT "$cfg/config"; then echo "unset left the key" >&2; exit 1; fi
    "$1" version | grep -q "^Limits: memory=4g "
    [ "$("$1" config path)" = "$cfg/config" ]
    # Environment wins over the file and the command says so.
    SAGENT_TOOLS=js "$1" tools disable tsx 2>&1 | grep -q "takes precedence"
    # Java tools drop out without a JDK; naming one explicitly is an error.
    SAGENT_TOOLS=all SAGENT_JAVA_VERSION=none "$1" version | grep -q "^Tools: typescript tsx bun corepack create-next-app create-vite shadcn$"
    if SAGENT_TOOLS=maven SAGENT_JAVA_VERSION=none "$1" version >/dev/null 2>&1; then echo "java tool without JDK accepted" >&2; exit 1; fi
    bash -n "$cfg/config"
' _ "$SCLAUDE"

# ── T39: status snapshot ─────────────────────────────────────────────
run_test "T39: status snapshot" bash -ec '
    export SAGENT_SKIP_RELEASE_CHECK=1
    out=$("$1" status)
    for key in Wrapper Latest Config Engine Image Toolchain Tools "CA bundle" Nested Limits Credentials Volumes Workspace; do
        echo "$out" | grep -q "^$key:" || { echo "status lacks a $key line" >&2; exit 1; }
    done
    echo "$out" | grep -q "^Engine: .*CLI: $(echo "$out" | sed -n "s/^Engine: .*CLI: \([a-z]*\),.*/\1/p")"
    echo "$out" | grep -q "^Image: .*$SUITE_IMG"
    echo "$out" | grep -q "^Toolchain: *ubuntu="
    echo "$out" | grep -qE "^Workspace: .*(git: |not a git repository)"
    # No engine: status still prints, naming the problem instead of failing.
    SAGENT_CONTAINER_ENGINE=/nonexistent/engine "$1" status | grep -q "^Engine: .*none responding"
' _ "$SCLAUDE"

# ── T40: doctor diagnostics ──────────────────────────────────────────
# A healthy setup with a built image has no FAIL lines and exits 0; the
# checks that spot real problems (missing engine, unmountable workspace,
# rootless docker CLI) report FAIL and exit 1.
run_test "T40: doctor diagnostics" bash -ec '
    export SAGENT_SKIP_RELEASE_CHECK=1
    out=$("$1" doctor) || { echo "$out" >&2; echo "doctor failed on a healthy setup" >&2; exit 1; }
    echo "$out" | grep -qE "^  PASS  engine "
    echo "$out" | grep -qE "^  PASS  workspace "
    echo "$out" | grep -qE "^  PASS  build-tls "
    echo "$out" | grep -qE "^  PASS  image +$SUITE_IMG"
    echo "$out" | grep -qE "^  PASS  cli:claude "
    echo "$out" | grep -qE "^  PASS  cli:gh "
    echo "$out" | grep -qE "^  PASS  network "
    echo "$out" | grep -qE "^  PASS  nested "
    echo "$out" | grep -qE "^  PASS  caches "
    echo "$out" | grep -qE "^Summary: [0-9]+ passed, [0-9]+ warning\(s\), 0 failed$"
    if echo "$out" | grep -q "^  FAIL"; then echo "$out" >&2; exit 1; fi
    # Missing engine: FAIL line, exit 1, and the rest of the report still prints.
    if out=$(SAGENT_CONTAINER_ENGINE=/nonexistent/engine "$1" doctor); then echo "doctor should exit 1 without an engine" >&2; exit 1; fi
    echo "$out" | grep -qE "^  FAIL  engine "
    echo "$out" | grep -qE "^  (PASS|WARN)  auth:claude "
    echo "$out" | grep -q "^Summary: .* 1 failed$"
    # Stub rootless podman behind the docker CLI: workspace check fails.
    tmp=$(mktemp -d /tmp/sagent-t40.XXXXXX)
    trap "rm -rf \"$tmp\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) [ "\${2:-}" = "--format" ] && echo "name=rootless"; exit 0 ;;
    version) printf "Client: Docker Engine\nServer:\n Podman Engine:\n"; exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    if out=$(SAGENT_CONTAINER_ENGINE="$tmp/fake-engine" "$1" doctor); then echo "doctor should exit 1 on a rootless docker CLI" >&2; exit 1; fi
    echo "$out" | grep -qE "^  FAIL  workspace .*rootless podman daemon"
' _ "$SCLAUDE"

# ── T41: TLS interception fixed from the host trust store before building ─
# #77: a stub engine answers the pre-build probe with TLS-FAIL until a bundle
# arrives on stdin, then with TLS-OK. The wrapper must export the host trust
# store, verify it, persist the bundle and setting, and build with the CA
# block; with a bundle that still fails it must stop naming the issuer.
run_test "T41: TLS interception auto-fixed from host trust store" bash -ec '
    tmp=$(mktemp -d /tmp/sagent-t41.XXXXXX)
    trap "rm -rf \"$tmp\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) exit 0 ;;
    version) printf "Client: Docker Engine\nServer: Docker Engine\n"; exit 0 ;;
    run)
        if [ ! -f "$tmp/never-ok" ] && grep -q "BEGIN CERTIFICATE" 2>/dev/null; then echo TLS-OK; else printf "TLS-FAIL\n* issuer: CN=Corp Proxy Root CA\n"; fi
        exit 0 ;;
    build)
        for last; do :; done
        cp "\$last/Dockerfile" "$tmp/Dockerfile"
        (cd "\$last" && find . -type f | sort) > "$tmp/context.txt"
        echo "STUB-BUILT"; exit 0 ;;
    image) exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/fake-engine" SAGENT_CONFIG_FILE="$tmp/cfg/config"
    "$1" --build >"$tmp/out" 2>"$tmp/err"
    grep -q "This network intercepts TLS (chain issuer: CN=Corp Proxy Root CA)" "$tmp/err"
    grep -q "The host trust store has it" "$tmp/err"
    grep -q "SAGENT_CA_BUNDLE" "$tmp/cfg/config"
    grep -q -- "-----BEGIN CERTIFICATE-----" "$tmp/cfg/ca-bundle.pem"
    grep -q "^COPY sagent-ca/" "$tmp/Dockerfile"
    grep -q "sagent-ca-bundle.pem" "$tmp/context.txt"
    grep -q STUB-BUILT "$tmp/out"
    # The persisted setting makes the next run skip the export: the probe
    # answers TLS-OK for the configured bundle and no new message appears.
    "$1" --build >"$tmp/out2" 2>"$tmp/err2"
    if grep -q "intercepts TLS" "$tmp/err2"; then echo "second run should have used the persisted bundle" >&2; exit 1; fi
    grep -q "Baking" "$tmp/err2"
    # The wrapper-managed bundle is refreshed from the host trust store when
    # it stops matching (an older System-keychain-only export).
    printf "%s\n" "-----BEGIN CERTIFICATE-----" "SAGENT-T41-STALE" "-----END CERTIFICATE-----" > "$tmp/cfg/ca-bundle.pem"
    sed -i.bak "s|grep -q \"BEGIN CERTIFICATE\"|! grep -q SAGENT-T41-STALE|" "$tmp/fake-engine"   # the stub now rejects the stale bundle only
    "$1" --build >"$tmp/out4" 2>"$tmp/err4"
    grep -q "does not contain that CA; refreshing it from the host trust store" "$tmp/err4"
    grep -q "The host trust store has it" "$tmp/err4"
    if grep -q SAGENT-T41-STALE "$tmp/cfg/ca-bundle.pem"; then echo "managed bundle was not refreshed" >&2; exit 1; fi
    grep -q STUB-BUILT "$tmp/out4"
    # A user-supplied bundle that does not contain the CA stops before the build.
    printf "%s\n" "-----BEGIN CERTIFICATE-----" "SAGENT-T41-STALE" "-----END CERTIFICATE-----" > "$tmp/other.pem"
    touch "$tmp/never-ok"   # the stub now rejects every bundle
    if SAGENT_CA_BUNDLE="$tmp/other.pem" "$1" --build >/dev/null 2>"$tmp/err3"; then echo "build should stop when the bundle lacks the CA" >&2; exit 1; fi
    grep -q "does not contain that CA" "$tmp/err3"
    grep -q "CN=Corp Proxy Root CA" "$tmp/err3"
' _ "$SCLAUDE"

# ── T42: scodex login uses device-code sign-in ────────────────────────
# #78: a stub engine records the container command line.
run_test "T42: scodex login uses device-code sign-in" bash -ec '
    tmp=$(mktemp -d /tmp/sagent-t42.XXXXXX)
    trap "rm -rf \"$tmp\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) exit 0 ;;
    version) printf "Client: Docker Engine\nServer: Docker Engine\n"; exit 0 ;;
    context) echo desktop-linux; exit 0 ;;
    image | volume) exit 0 ;;
    ps) exit 0 ;;
    run) echo "STUB-RUN \$*"; exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/fake-engine"
    "$1" login 2>"$tmp/err" | grep -qE "STUB-RUN .* codex --dangerously-bypass-approvals-and-sandbox login --device-auth$"
    grep -q "device-code sign-in" "$tmp/err"
    "$1" login --with-api-key 2>/dev/null | grep -qE " codex .*login --with-api-key$"
    "$1" login status 2>/dev/null | grep -qE " codex .*login status$"
    "$1" exec --help 2>/dev/null | grep -qE " codex .*exec --help$"
    # The tool container carries the workspace label the shell command attaches by.
    "$1" --help 2>/dev/null | grep -q -- "--label sagent.workspace=$PWD "
' _ "$SCODEX"

# ── T43: shell into the sandbox ───────────────────────────────────────
run_test "T43: shell command (fresh and attached)" bash -ec '
    export SAGENT_SKIP_RELEASE_CHECK=1
    WS=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t43.XXXXXX")
    trap "rm -rf \"$WS\"; \"$ENGINE\" rm -f sagent-t43-running >/dev/null 2>&1" EXIT
    echo t43-marker > "$WS/probe.txt"
    # Fresh shell: same workspace mount, no yolo flag, arguments go to bash.
    out=$(cd "$WS" && "$1" shell -c "cat probe.txt; whoami" 2>"$WS/err")
    echo "$out" | grep -q t43-marker
    echo "$out" | grep -q "^agent$"
    grep -q "starting a fresh one" "$WS/err"
    # Attached shell: a sandbox running for this workspace (by label) is joined.
    "$ENGINE" run -d --name sagent-t43-running --label "sagent.workspace=$WS" $SAGENT_TEST_USERNS \
        -v "$(cd "$WS" && pwd -P):$WS:rw" -w "$WS" "$SUITE_IMG" sleep 120 >/dev/null
    cid=$("$ENGINE" ps -q --filter name=sagent-t43-running | head -1)
    out=$(cd "$WS" && "$1" shell -c "hostname" 2>"$WS/err")
    grep -q "Attaching a shell to the sandbox running for $WS" "$WS/err"
    [ "$out" = "${cid:0:12}" ]
' _ "$SCLAUDE"

# ── T44: install and migrate without sudo ────────────────────────────
# `install` puts both wrappers somewhere the user owns and makes sure that
# directory is on PATH; running it again changes nothing. `update` moves an
# install that lives outside the home directory (one that needed sudo) into
# that same place. The release install path is the copy, not the symlink a
# checkout gets, so the wrappers are copied out of the checkout first.
run_test "T44: install and migrate without sudo" bash -ec '
    TMP=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t44.XXXXXX")
    trap "rm -rf \"$TMP\"" EXIT
    # Physical path throughout: on macOS $TMPDIR is reached through a
    # symlink, and the wrapper resolves what it installs into.
    TMP=$(cd "$TMP" && pwd -P)
    mkdir -p "$TMP/home" "$TMP/sysbin"
    cp "$1" "$(dirname "$1")/scodex" "$TMP/sysbin/"
    chmod +x "$TMP/sysbin/sclaude" "$TMP/sysbin/scodex"
    target="$TMP/home/.local/bin"

    out=$(HOME="$TMP/home" SHELL=/bin/bash PATH="/usr/bin:/bin" "$TMP/sysbin/sclaude" install "$target" 2>&1)
    echo "$out"
    if echo "$out" | grep -q sudo; then
        echo "install used or mentioned sudo" >&2
        exit 1
    fi
    # Both wrappers are there as real copies and run.
    [ -x "$target/sclaude" ] && [ -x "$target/scodex" ] && [ ! -L "$target/sclaude" ]
    # A real wrapper, not a truncated copy. Checked without an engine so the
    # test says something about installing, not about docker being up.
    head -1 "$target/sclaude" | grep -qx "#!/usr/bin/env bash"
    grep -q "^SCRIPT_NAME=\"sclaude\"$" "$target/sclaude"
    grep -q "^SCRIPT_NAME=\"scodex\"$" "$target/scodex"
    bash -n "$target/sclaude" && bash -n "$target/scodex"
    # The rc file gained exactly one block, and it does put the directory on PATH.
    [ "$(grep -c "added by sclaude/scodex" "$TMP/home/.bashrc")" -eq 1 ]
    HOME="$TMP/home" bash -c "PATH=/usr/bin:/bin; . \"$TMP/home/.bashrc\"; case \":\$PATH:\" in *\":$target:\"*) exit 0 ;; esac; exit 1"
    # Running it again is a no-op.
    HOME="$TMP/home" SHELL=/bin/bash PATH="/usr/bin:/bin" "$target/sclaude" install "$target" >/dev/null 2>&1
    [ "$(grep -c "added by sclaude/scodex" "$TMP/home/.bashrc")" -eq 1 ]
    # An rc that already puts the directory on PATH is left alone.
    printf "export PATH=\"\$HOME/.local/bin:\$PATH\"\n" > "$TMP/home/.bash_profile"
    before=$(wc -l < "$TMP/home/.bash_profile")
    HOME="$TMP/home" SHELL=/bin/bash PATH="/usr/bin:/bin" "$target/sclaude" install "$target" >/dev/null 2>&1
    [ "$(wc -l < "$TMP/home/.bash_profile")" -eq "$before" ]

    # Migration: an install outside the home directory moves into it. The
    # fixture directory is writable, so no sudo is needed to clear it.
    rm -rf "$target" "$TMP/home/.bashrc" "$TMP/home/.bash_profile"
    # Full PATH here: update needs to find the engine. The install steps
    # above are the ones that must not depend on it.
    out=$(HOME="$TMP/home" SHELL=/bin/bash \
        SAGENT_SKIP_SELF_UPDATE=1 SAGENT_SKIP_RELEASE_CHECK=1 \
        "$TMP/sysbin/sclaude" update 2>&1) || true
    echo "$out"
    echo "$out" | grep -q "Moving it to $target"
    [ -x "$target/sclaude" ] && [ -x "$target/scodex" ]
    [ ! -e "$TMP/sysbin/sclaude" ] && [ ! -e "$TMP/sysbin/scodex" ]
    [ "$(grep -c "added by sclaude/scodex" "$TMP/home/.bashrc")" -eq 1 ]
    # A checkout is left where it is.
    out=$(HOME="$TMP/home" SAGENT_SKIP_SELF_UPDATE=1 SAGENT_SKIP_RELEASE_CHECK=1 "$1" update 2>&1) || true
    if echo "$out" | grep -q "which needed sudo"; then
        echo "a git checkout must not be migrated" >&2
        exit 1
    fi
' _ "$SCLAUDE"

print_results
