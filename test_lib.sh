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
    local timer_children
    local timer_child
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
    # The timer is a subshell whose `sleep` is a separate process: killing
    # only the subshell leaves the sleep running to full term, which is why
    # CI cleanup used to terminate dozens of orphans per job. Its children
    # have to be noted before it dies, since they reparent away from it.
    timer_children=$(pgrep -P "$timer_pid" 2>/dev/null || true)
    kill "$timer_pid" 2>/dev/null || true
    for timer_child in $timer_children; do
        kill "$timer_child" 2>/dev/null || true
    done
    wait "$timer_pid" 2>/dev/null || true

    if [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
        printf 'Timed out after %s seconds\n' "$TEST_TIMEOUT_SECONDS" >> "$output_file"
    fi
    return "$rc"
}

# Did this test fail because the engine went away underneath it? Container
# engines on CI runners do fall over mid-suite: the Rancher Desktop VM has
# lost its network with the suite half-run, failing tests that had nothing
# to do with it.
engine_went_away() {
    grep -qiE "engine is not responding|cannot connect to the docker daemon|no network from containers|error during connect|connection refused.*docker" "$1"
}

# Wait, bounded, for the engine to answer again. Returns 1 if it never does,
# which leaves the original failure standing.
wait_for_engine() {
    local engine="${ENGINE:-${SAGENT_CONTAINER_ENGINE:-docker}}" _
    for _ in $(seq 1 24); do
        if "$engine" info >/dev/null 2>&1; then return 0; fi
        sleep 5
    done
    return 1
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
    local rc=0
    output_file=$(mktemp)
    run_with_timeout_capture "$output_file" "$@" || rc=$?
    # An engine that died takes unrelated tests with it. Say so out loud and
    # give the test one more run once the engine answers again — never a
    # silent retry, and never one for a test that failed on its own merits.
    if [ "$rc" -ne 0 ] && engine_went_away "$output_file"; then
        printf "RETRY(engine) "
        if wait_for_engine; then
            rc=0
            : > "$output_file"
            run_with_timeout_capture "$output_file" "$@" || rc=$?
        fi
    fi
    output=$(cat "$output_file")
    rm -f "$output_file"
    if [ "$rc" -eq 0 ]; then
        printf "PASS\n"
        PASS=$((PASS + 1))
    else
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
