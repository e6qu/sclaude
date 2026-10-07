#!/usr/bin/env bash
# Exercise failure capture without running a container or BuildKit daemon.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp=$(mktemp -d /tmp/sagent-diagnostics-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# Extract only the actual reporting function; the scenario itself must
# never run on the host. A long dump and supervisor restart reproduce the
# loss of the fatal header with the old last-40-lines diagnostics.
eval "$(sed -n '/^report_buildkit_failure()/,/^}/p' "$SCRIPT_DIR/test_nested.sh")"
mkdir -p "$tmp/cgroup"
printf 'max 3\n' > "$tmp/cgroup/pids.events"
printf 'oom 0\noom_kill 0\n' > "$tmp/cgroup/memory.events"
{
    printf 'panic: previous failure\nprevious stack\n'
    seq 1 100
    printf 'SIGSEGV: segmentation violation\nPC=0x1234\nruntime.exitsyscall()\n'
    seq 1 800
    printf 'supervisor restarted daemon\n'
} > "$tmp/daemon.log"
report_buildkit_failure "$tmp/daemon.log" "$tmp/cgroup" > "$tmp/report"
tail -n 120 "$tmp/report" > "$tmp/tail"
grep -F 'SIGSEGV: segmentation violation' "$tmp/tail" >/dev/null
grep -F 'runtime.exitsyscall()' "$tmp/tail" >/dev/null
grep -F 'pids.events: max 3' "$tmp/tail" >/dev/null
grep -F 'oom_kill 0' "$tmp/tail" >/dev/null
grep -F 'supervisor restarted daemon' "$tmp/tail" >/dev/null
grep -F 'previous stack' "$tmp/report" >/dev/null
# Missing logs or cgroup counters do not obscure the original failure.
report_buildkit_failure "$tmp/missing" "$tmp/missing-cgroup" > /dev/null

# Test the real harness with a failure whose cause is above its console
# tail. It must retain the full output artifact and still report failure.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/pgrep" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$tmp/bin/pgrep"
PATH="$tmp/bin:$PATH" SAGENT_TEST_LOG_DIR="$tmp/artifacts" \
    TEST_TIMEOUT_SECONDS=2 SAGENT_TEST_SHARD='' SAGENT_TEST_SKIP='' FAIL_OUTPUT_LINES=5 \
    bash -c '
        . "$1"
        run_test "T99: synthetic failure" sh -c "printf cause-at-start\\n; seq 1 100; exit 1"
        [ "$FAIL" = 1 ] && [ "$PASS" = 0 ]
    ' _ "$SCRIPT_DIR/test_lib.sh" > "$tmp/console"
grep -F cause-at-start "$tmp/artifacts/T99.log" >/dev/null
grep -F 'T99: synthetic failure' "$tmp/console" >/dev/null
grep -F FAIL "$tmp/console" >/dev/null

# A recovered daemon crash must remain visible even when the test passes.
for reason in 'lost its session' 'crashed with SIGILL'; do
    PATH="$tmp/bin:$PATH" SAGENT_TEST_LOG_DIR="$tmp/recoveries" \
        TEST_TIMEOUT_SECONDS=2 SAGENT_TEST_SHARD='' SAGENT_TEST_SKIP='' \
        bash -c '
            . "$1"
            run_test "T60: recovered browser build" sh -c '\''
                printf "first-attempt-evidence\n"
                printf "BuildKit %s; retrying the browser fixture once with cached layers\n" "$1"
                printf "second-attempt-evidence\n"
            '\'' _ "$2"
            [ "$PASS" = 1 ] && [ "$FAIL" = 0 ]
        ' _ "$SCRIPT_DIR/test_lib.sh" "$reason" > "$tmp/recovery-console"
    grep -F 'RETRY(buildkit) PASS' "$tmp/recovery-console" >/dev/null
    grep -F first-attempt-evidence "$tmp/recoveries/T60.log" >/dev/null
    grep -F second-attempt-evidence "$tmp/recoveries/T60.log" >/dev/null
done

# A clean success saves nothing, and recovery evidence must be writable.
for mode in healthy unwritable; do
    artifact_path="$tmp/$mode-artifacts"
    if [ "$mode" = unwritable ]; then printf blocked > "$artifact_path"; fi
    PATH="$tmp/bin:$PATH" SAGENT_TEST_LOG_DIR="$artifact_path" \
        TEST_TIMEOUT_SECONDS=2 SAGENT_TEST_SHARD='' SAGENT_TEST_SKIP='' \
        bash -c '
            . "$1"
            if [ "$2" = healthy ]; then
                run_test "T60: clean build" sh -c "printf healthy\\n"
                [ "$PASS" = 1 ] && [ "$FAIL" = 0 ]
                [ ! -e "$SAGENT_TEST_LOG_DIR" ]
            else
                run_test "T60: unwritable recovery" sh -c '\''
                    printf "BuildKit crashed with SIGILL; retrying the browser fixture once with cached layers\n"
                '\''
                [ "$PASS" = 0 ] && [ "$FAIL" = 1 ]
            fi
        ' _ "$SCRIPT_DIR/test_lib.sh" "$mode" > "$tmp/$mode-console" 2>&1
done
grep -F 'Could not preserve the recovery capture' "$tmp/unwritable-console" >/dev/null
grep -F FAIL "$tmp/unwritable-console" >/dev/null

# Run the real T43 body against stubs. Both shell invocations must print
# their captured stderr before the workspace's EXIT trap removes it.
sed -n '/^run_test "T43:/,/^#.*T44:/p' "$SCRIPT_DIR/test_e2e.sh" > "$tmp/t43"
cat > "$tmp/bin/shell-wrapper" <<'SH'
#!/bin/sh
if [ "$SHELL_FAILURE_MODE" = fresh ] || [ "$3" = hostname ]; then
    echo "$SHELL_FAILURE_MODE-shell-failure" >&2
    exit 42
fi
cat probe.txt
echo agent
echo 'starting a fresh one' >&2
SH
cat > "$tmp/bin/engine" <<'SH'
#!/bin/sh
if [ "$1" = ps ]; then echo 123456789abc; fi
exit 0
SH
chmod +x "$tmp/bin/shell-wrapper" "$tmp/bin/engine"
for mode in fresh attached; do
    rc=0
    SHELL_FAILURE_MODE="$mode" SAGENT_TEST_TMPDIR="$tmp" \
        SCLAUDE="$tmp/bin/shell-wrapper" ENGINE="$tmp/bin/engine" \
        SAGENT_TEST_USERNS='' SUITE_IMG=stub bash -c '
            run_test() { shift; "$@"; }
            . "$1"
        ' _ "$tmp/t43" > "$tmp/shell-failure" 2>&1 || rc=$?
    [ "$rc" = 42 ]
    grep -F "$mode-shell-failure" "$tmp/shell-failure" >/dev/null
done
printf 'Long daemon dumps retain their fatal header, resource counters and full capture\n'
printf 'Fresh and attached shell failures retain stderr before cleanup\n'
