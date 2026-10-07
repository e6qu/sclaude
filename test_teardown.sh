#!/usr/bin/env bash
# Exercise late exit notifications without a container engine or real sleeps.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_lib.sh disable=SC1091
. "$SCRIPT_DIR/test_lib.sh"
tmp=$(mktemp -d /tmp/sagent-teardown-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
export TEARDOWN_TEST_ROOT="$tmp"
export TEARDOWN_TEST_MODE=transient
cat > "$tmp/engine" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ]
[ "$1" = rm ]
[ "$2" = -f ]
[ "$3" = fixture ]
n=$(cat "$TEARDOWN_TEST_ROOT/count" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$TEARDOWN_TEST_ROOT/count"
case "$TEARDOWN_TEST_MODE:$n" in
    transient:1 | progress:1 | permanent:*)
        printf '%s\n' 'could not kill container: tried to kill container, but did not receive an exit event' >&2
        exit 1 ;;
    progress:2)
        printf '%s\n' 'removal of container fixture is already in progress' >&2
        exit 1 ;;
    unrelated:*)
        printf '%s\n' 'cannot connect to the container engine' >&2
        exit 125 ;;
esac
SH
chmod +x "$tmp/engine"
sleep() { printf '%s\n' "$*" >> "$tmp/sleeps"; }

# The old single rm fails on the same error seen in Rancher's T66 capture.
if "$tmp/engine" rm -f fixture 2>"$tmp/err"; then
    printf '%s\n' 'The delayed-exit reproducer unexpectedly succeeded' >&2
    exit 1
fi
grep -F 'did not receive an exit event' "$tmp/err" >/dev/null
for mode in transient progress permanent unrelated; do
    TEARDOWN_TEST_MODE="$mode"
    rm -f "$tmp/count" "$tmp/sleeps"
    rc=0
    remove_test_container "$tmp/engine" fixture 2>"$tmp/err" || rc=$?
    case "$mode" in
        transient)
            [ "$rc" -eq 0 ]
            [ "$(cat "$tmp/count")" -eq 2 ]
            [ "$(wc -l < "$tmp/sleeps" | tr -d ' ')" -eq 1 ] ;;
        progress)
            [ "$rc" -eq 0 ]
            [ "$(cat "$tmp/count")" -eq 3 ]
            [ "$(wc -l < "$tmp/sleeps" | tr -d ' ')" -eq 2 ] ;;
        permanent)
            [ "$rc" -eq 1 ]
            [ "$(cat "$tmp/count")" -eq 6 ]
            [ "$(wc -l < "$tmp/sleeps" | tr -d ' ')" -eq 5 ]
            grep -F 'not removed after six attempts' "$tmp/err" >/dev/null ;;
        unrelated)
            [ "$rc" -eq 125 ]
            [ "$(cat "$tmp/count")" -eq 1 ]
            [ ! -e "$tmp/sleeps" ]
            grep -F 'cannot connect to the container engine' "$tmp/err" >/dev/null ;;
    esac
    printf '%s: container removal regression passed\n' "$mode"
done
