#!/usr/bin/env bash
# Exercise T60's session recovery without starting a container or a VM.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp=$(mktemp -d /tmp/sagent-nested-retry.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
export NESTED_RETRY_TEST_ROOT="$tmp"
mkdir "$tmp/bin"
sed -n '/^build_nested_browser()/,/^}/p' "$SCRIPT_DIR/test_nested.sh" > "$tmp/helper"
[ -s "$tmp/helper" ]
cat > "$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ]
[ "$1" = compose ]
[ "$2" = build ]
[ "$3" = browser ]
n=$(cat "$NESTED_RETRY_TEST_ROOT/count" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$NESTED_RETRY_TEST_ROOT/count"
printf 'attempt-%s layer-output\n' "$n"
case "$NESTED_RETRY_TEST_MODE:$n" in
    transient:1 | persistent:* | second-error:1)
        printf '%s\n' 'failed to solve: DeadlineExceeded: no active session for fixture-session: context deadline exceeded' >&2
        exit 1 ;;
    second-error:2)
        printf '%s\n' 'RUN command failed' >&2
        exit 17 ;;
    build-error:*)
        printf '%s\n' 'failed to solve: process did not complete successfully' >&2
        exit 42 ;;
    other-timeout:*)
        printf '%s\n' 'failed to solve: DeadlineExceeded: registry request: context deadline exceeded' >&2
        exit 28 ;;
esac
SH
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH"
for mode in healthy transient persistent second-error build-error other-timeout capture-error; do
    rm -f "$tmp/count"
    rc=0
    NESTED_RETRY_TEST_MODE="$mode" bash -euo pipefail -c '
        . "$1"
        if [ "$NESTED_RETRY_TEST_MODE" = capture-error ]; then
            tee() { cat; return 74; }
        fi
        build_nested_browser "$2"
    ' _ "$tmp/helper" "$tmp/build.log" > "$tmp/output" 2>&1 || rc=$?
    grep -F 'attempt-1 layer-output' "$tmp/output" >/dev/null
    case "$mode" in
        healthy)
            [ "$rc" -eq 0 ]
            [ "$(cat "$tmp/count")" -eq 1 ] ;;
        transient)
            [ "$rc" -eq 0 ]
            [ "$(cat "$tmp/count")" -eq 2 ] ;;
        persistent)
            [ "$rc" -eq 1 ]
            [ "$(cat "$tmp/count")" -eq 2 ] ;;
        second-error)
            [ "$rc" -eq 17 ]
            [ "$(cat "$tmp/count")" -eq 2 ]
            grep -F 'RUN command failed' "$tmp/output" >/dev/null ;;
        build-error)
            [ "$rc" -eq 42 ]
            [ "$(cat "$tmp/count")" -eq 1 ] ;;
        other-timeout)
            [ "$rc" -eq 28 ]
            [ "$(cat "$tmp/count")" -eq 1 ] ;;
        capture-error)
            [ "$rc" -eq 74 ]
            [ "$(cat "$tmp/count")" -eq 1 ] ;;
    esac
    case "$mode" in
        transient | persistent | second-error)
            grep -F 'no active session for fixture-session' "$tmp/output" >/dev/null
            grep -F 'retrying the browser fixture once' "$tmp/output" >/dev/null
            grep -F 'attempt-2 layer-output' "$tmp/output" >/dev/null ;;
        *)
            if grep -F 'retrying the browser fixture once' "$tmp/output" >/dev/null; then
                printf 'Unexpected retry for %s\n' "$mode" >&2
                exit 1
            fi ;;
    esac
    printf '%s: nested build session regression passed\n' "$mode"
done
