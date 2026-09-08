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

SUITE_IMG="sagent-sandbox:1758f3bc"; export SUITE_IMG
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

print_results
