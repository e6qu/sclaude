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
printf 'Long daemon dumps retain their fatal header, resource counters and full capture\n'
