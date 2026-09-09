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

SUITE_IMG="sagent-sandbox:$(SAGENT_SKIP_RELEASE_CHECK=1 "$SCLAUDE" version 2>/dev/null | sed -n "s/^Image hash: //p")"; export SUITE_IMG; echo "IMG=$SUITE_IMG"
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

print_results
