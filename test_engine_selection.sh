#!/usr/bin/env bash
# Exercise real engine selection and bounded probes without containers or VMs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then set -- "$SCRIPT_DIR/sclaude" "$SCRIPT_DIR/scodex"; fi
tmp=$(mktemp -d /tmp/sagent-engine-selection.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export ENGINE_SELECTION_TEST_ROOT="$tmp"
cat > "$tmp/bin/requested-engine" <<'SH'
#!/bin/sh
printf '%s\n' requested >> "$ENGINE_SELECTION_TEST_ROOT/calls"
[ "$1" = info ] || exit 1
case "$ENGINE_SELECTION_TEST_MODE" in
    fast) exit 0 ;;
    slow) exec sleep 2 ;;
    failed) exit 42 ;;
    *) exit 1 ;;
esac
SH
cat > "$tmp/bin/docker" <<'SH'
#!/bin/sh
printf '%s\n' fallback >> "$ENGINE_SELECTION_TEST_ROOT/calls"
exit 0
SH
chmod +x "$tmp/bin/"*
for wrapper in "$@"; do
    sed -n '/^run_with_timeout_quiet()/,/^}/p; /^select_engine()/,/^}/p' "$wrapper" > "$tmp/functions"
    for scenario in fast slow short failed missing; do
        : > "$tmp/calls"
        ENGINE_SELECTION_TEST_MODE="$scenario" PATH="$tmp/bin:/usr/bin:/bin" bash -euo pipefail -c '
            . "$1"
            # Hints are unrelated to selection; never query the host VM.
            stopped_engine_hints() { :; }
            SCRIPT_NAME=engine-selection-test
            ENGINE_CMD=unchanged
            SAGENT_CONTAINER_ENGINE=requested-engine
            ENGINE_TIMEOUT_SECONDS=15
            expected=0
            case "$2" in
                short) export ENGINE_SELECTION_TEST_MODE=slow; ENGINE_TIMEOUT_SECONDS=1; expected=1 ;;
                failed) expected=1 ;;
                missing) SAGENT_CONTAINER_ENGINE=missing-engine; expected=1 ;;
            esac
            rc=0
            select_engine || rc=$?
            [ "$rc" = "$expected" ]
            if [ "$expected" = 0 ]; then
                [ "$ENGINE_CMD" = requested-engine ]
            else
                [ "$ENGINE_CMD" = unchanged ]
            fi
        ' _ "$tmp/functions" "$scenario" > "$tmp/out" 2> "$tmp/err" || {
            printf '%s: explicit-engine scenario %s failed\n' "$(basename "$wrapper")" "$scenario" >&2
            cat "$tmp/out" "$tmp/err" >&2
            exit 1
        }
        if [ "$scenario" = missing ]; then
            [ ! -s "$tmp/calls" ]
            grep -F 'requested container engine not found: missing-engine' "$tmp/err" >/dev/null
        else
            [ "$(cat "$tmp/calls")" = requested ]
            case "$scenario" in
                short|failed) grep -F 'requested container engine is not responding: requested-engine' "$tmp/err" >/dev/null ;;
                *) [ ! -s "$tmp/err" ] ;;
            esac
        fi
    done
    printf '%s: fast, slow, timed-out, failed and missing explicit engines passed\n' "$(basename "$wrapper")"
done
