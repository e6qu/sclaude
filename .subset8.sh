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
# ── T19c: clipboard bridge round trip ────────────────────────────────
# The wrapper's clipboard agent (host side, sourced from the wrapper) serves
# the sandbox's clipboard shims through a bind-mounted directory. A fake
# host clipboard (pbcopy/pbpaste/osascript on macOS, xclip under DISPLAY on
# Linux) records what the agent does, so this runs on headless CI too.
run_test "T19c: clipboard bridge round trip" bash -ec '
    TMP=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t19c.XXXXXX")
    trap "kill \$AGENT 2>/dev/null; rm -rf \"$TMP\"" EXIT
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

print_results
