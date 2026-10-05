#!/usr/bin/env bash
# Exercise the real shell lookup against a stub engine, without containers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then set -- "$SCRIPT_DIR/sclaude" "$SCRIPT_DIR/scodex"; fi
tmp=$(mktemp -d /tmp/sagent-shell-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/engine" <<'SH'
#!/bin/sh
case "$1" in
    ps)
        if [ "$SHELL_TEST_MODE" = fail ]; then
            echo 'engine-listing-unavailable' >&2
            exit 42
        fi
        if [ "$SHELL_TEST_MODE" = large ]; then
            # Exceed pipe buffers so selecting with head causes SIGPIPE.
            awk 'BEGIN { print "first-sandbox"; for (i = 0; i < 20000; i++) print "another-sandbox-" i }'
        fi
        ;;
    exec) printf '%s\n' "$*" ;;
    *) exit 1 ;;
esac
SH
chmod +x "$tmp/engine"
for wrapper in "$@"; do
    sed -n '/^open_shell()/,/^}/p' "$wrapper" > "$tmp/open-shell"
    for mode in fail large empty; do
        rc=0
        SHELL_TEST_MODE="$mode" bash -euo pipefail -c '
            . "$1"
            ENGINE_CMD="$2"
            WORKSPACE_PATH=/workspace
            SCRIPT_NAME=sagent-test
            DOCKER_TTY_FLAGS=(-i)
            ARGS=(-c hostname)
            TOOL_BIN=claude
            YOLO=true
            open_shell
            [ "$TOOL_BIN" = bash ] && [ "$YOLO" = false ]
        ' _ "$tmp/open-shell" "$tmp/engine" > "$tmp/out" 2> "$tmp/err" || rc=$?
        case "$mode" in
            fail)
                [ "$rc" = 42 ]
                grep -F engine-listing-unavailable "$tmp/err" >/dev/null
                [ ! -s "$tmp/out" ]
                ;;
            large)
                [ "$rc" = 0 ]
                grep -Fx 'exec -i -w /workspace first-sandbox bash -c hostname' "$tmp/out" >/dev/null
                ;;
            empty)
                [ "$rc" = 0 ]
                grep -F 'starting a fresh one' "$tmp/err" >/dev/null
                ;;
        esac
    done
    printf '%s: failed, large and empty shell lookups passed\n' "$(basename "$wrapper")"
done
