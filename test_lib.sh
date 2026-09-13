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
# How much of a failed test's capture to print. Tests run traced, so the
# tail of it holds the commands that led to the failure.
FAIL_OUTPUT_LINES="${FAIL_OUTPUT_LINES:-30}"
# "2/3" runs every third test from the second. Tests are numbered in file
# order, skipped or not, so every slice agrees on which test is which.
SAGENT_TEST_SHARD="${SAGENT_TEST_SHARD:-}"
TEST_INDEX=0
SHARDED_OUT=0
if [ -n "$SAGENT_TEST_SHARD" ]; then
    case "$SAGENT_TEST_SHARD" in
        [1-9]/[1-9] | [1-9]/[1-9][0-9]) ;;
        *) echo "SAGENT_TEST_SHARD=\"$SAGENT_TEST_SHARD\" is not k/n" >&2; exit 1 ;;
    esac
    SHARD_K=${SAGENT_TEST_SHARD%/*}
    SHARD_N=${SAGENT_TEST_SHARD#*/}
    if [ "$SHARD_K" -gt "$SHARD_N" ]; then
        echo "SAGENT_TEST_SHARD=\"$SAGENT_TEST_SHARD\": slice $SHARD_K of $SHARD_N does not exist" >&2
        exit 1
    fi
fi

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

    # `bash -x` on this shell only, so a failure names its command (#94).
    # SHELLOPTS would trace every descendant, wrappers included (#97);
    # BASH_XTRACEFD does not exist in macOS's bash 3.2.
    local -a traced=("$@")
    if [ "${traced[0]}" = bash ]; then
        traced=(bash -x "${traced[@]:1}")
    fi
    "${traced[@]}" >"$output_file" 2>&1 &
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
    # Note the timer's children before killing it: they reparent away from
    # it, and an orphaned sleep runs to full term.
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

# Did the engine go away underneath this test? (#90)
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
    TEST_INDEX=$((TEST_INDEX + 1))
    if [ -n "$SAGENT_TEST_SHARD" ] && [ $(( (TEST_INDEX - 1) % SHARD_N + 1 )) -ne "$SHARD_K" ]; then
        SHARDED_OUT=$((SHARDED_OUT + 1))
        return 0
    fi
    case " $SAGENT_TEST_SKIP " in
        *" ${name%%:*} "*)
            report_skip "$name" "SAGENT_TEST_SKIP"
            return 0
            ;;
    esac
    printf "  %-55s " "$name"
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
    local lines
    lines=$(wc -l < "$output_file" | tr -d " ")
    if [ "$rc" -eq 0 ]; then
        rm -f "$output_file"
        printf "PASS\n"
        PASS=$((PASS + 1))
    else
        printf "FAIL\n"
        if [ ! -s "$output_file" ]; then
            printf "    Output: (none — the test wrote nothing and was not traced)\n"
        elif [ "$lines" -gt "$FAIL_OUTPUT_LINES" ]; then
            printf "    Output (last %s of %s lines):\n" "$FAIL_OUTPUT_LINES" "$lines"
            tail -"$FAIL_OUTPUT_LINES" "$output_file" | sed "s/^/      /"
        else
            printf "    Output:\n"
            sed "s/^/      /" "$output_file"
        fi
        rm -f "$output_file"
        FAIL=$((FAIL + 1))
    fi
}

# A test that cannot run here (zsh not installed) still holds its place in
# the numbering, or every test after it would land in a different slice on
# a runner that has zsh than on one that does not.
skip_test() {
    TEST_INDEX=$((TEST_INDEX + 1))
    if [ -n "$SAGENT_TEST_SHARD" ] && [ $(( (TEST_INDEX - 1) % SHARD_N + 1 )) -ne "$SHARD_K" ]; then
        SHARDED_OUT=$((SHARDED_OUT + 1))
        return 0
    fi
    report_skip "$@"
}

report_skip() {
    local name="$1" reason="$2"
    printf "  %-55s SKIP (%s)\n" "$name" "$reason"
    SKIP=$((SKIP + 1))
}

print_results() {
    echo ""
    echo "=== Results ==="
    if [ -n "$SAGENT_TEST_SHARD" ]; then
        echo "  Slice:   $SAGENT_TEST_SHARD ($SHARDED_OUT tests belong to other slices)"
    fi
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
