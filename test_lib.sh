#!/usr/bin/env bash
# Shared test harness for test_e2e.sh and test_devcontainers.sh.

PASS=0
FAIL=0
SKIP=0
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-600}"
# Space-separated test IDs (e.g. "T10 T15") to skip — for CI jobs whose
# platform is slow enough that a test's cost outweighs its added coverage
# there. Skipped tests are reported as SKIP, never silently dropped.
SAGENT_TEST_SKIP="${SAGENT_TEST_SKIP:-}"

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
    case " $SAGENT_TEST_SKIP " in
        *" ${name%%:*} "*)
            skip_test "$name" "SAGENT_TEST_SKIP"
            return 0
            ;;
    esac
    printf "  %-55s " "$name"
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
    printf "  %-55s SKIP (%s)\n" "$name" "$reason"
    SKIP=$((SKIP + 1))
}

print_results() {
    echo ""
    echo "=== Results ==="
    echo "  Passed:  $PASS"
    echo "  Failed:  $FAIL"
    echo "  Skipped: $SKIP"
    echo ""
    if [ "$FAIL" -gt 0 ]; then
        echo "SOME TESTS FAILED"
        exit 1
    fi
    echo "ALL TESTS PASSED"
    exit 0
}
