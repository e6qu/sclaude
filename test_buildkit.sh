#!/usr/bin/env bash
# Exercise the generated service helper without Docker, BuildKit or a VM.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then set -- "$SCRIPT_DIR/sclaude" "$SCRIPT_DIR/scodex"; fi
tmp=$(mktemp -d /tmp/sagent-buildkit-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export BUILDKIT_TEST_ROOT="$tmp"

cat > "$tmp/bin/timeout" <<'PY'
#!/usr/bin/env python3
import subprocess
import sys

try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
cat > "$tmp/bin/buildctl" <<'SH'
#!/bin/sh
[ "$BUILDKIT_TEST_MODE" != down ] || exit 1
if [ "$BUILDKIT_TEST_MODE" = cold ]; then
    [ "$(cat "$BUILDKIT_TEST_ROOT/clock")" -ge 1090 ] || exit 1
fi
sleep "$BUILDKIT_TEST_DELAY"
SH
cat > "$tmp/bin/flock" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$BUILDKIT_TEST_ROOT/flock-calls"
SH
cat > "$tmp/bin/nohup" <<'SH'
#!/bin/sh
touch "$BUILDKIT_TEST_ROOT/supervisor-started"
SH
cat > "$tmp/bin/date" <<'SH'
#!/bin/sh
n=$(cat "$BUILDKIT_TEST_ROOT/clock" 2>/dev/null || echo 1000)
printf '%s\n' "$n"
printf '%s\n' "$((n + ${BUILDKIT_TEST_CLOCK_STEP:-60}))" > "$BUILDKIT_TEST_ROOT/clock"
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
printf '%s\n' "$tmp/storage" > "$tmp/storage-root"

for wrapper in "$@"; do
    # Execute the printf block that writes the image helper. Relocate its
    # socket/log and bypass only the host's missing /dev/fuse device.
    python3 - "$wrapper" "$tmp" <<'PY'
import pathlib
import shlex
import socket
import subprocess
import sys

source = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
end = source.index('        > /usr/local/bin/sagent-buildkit;')
start = source.rfind("    printf '%s\\n' \\", 0, end)
assert start >= 0
block = source[start:end].rstrip()
assert block.endswith('\\')
helper = subprocess.check_output(['bash', '-c', block[:-1] + '\n']).decode()
assert helper.count('[ -c /dev/fuse ] || exit 1') == 1
helper = helper.replace('[ -c /dev/fuse ] || exit 1', ': # host-only test')
helper = helper.replace('/usr/local/bin/sagent-container-storage || exit 1', ': # storage lease tested by T65')
helper = helper.replace('/run/sagent/storage-root', str(root / 'storage-root'))
helper = helper.replace('sock=/run/buildkit/buildkitd.sock', 'sock=' + shlex.quote(str(root / 'socket')))
helper = helper.replace('/tmp/sagent-buildkit.log', str(root / 'buildkit.log'))
(root / 'helper').write_text(helper)
sock = root / 'socket'
sock.unlink(missing_ok=True)
with socket.socket(socket.AF_UNIX) as listener:
    listener.bind(str(sock))
PY
    for delay in 0 1; do
        rm -f "$tmp/flock-calls" "$tmp/supervisor-started" "$tmp/clock"
        BUILDKIT_TEST_MODE=healthy BUILDKIT_TEST_DELAY="$delay" sh "$tmp/helper"
        [ ! -e "$tmp/supervisor-started" ]
        grep -F /tmp/sagent-buildx.lock "$tmp/flock-calls" >/dev/null
    done
    # Colima's cold worker discovery took 78 seconds before the server
    # listened. Advance a virtual clock to model a 90-second cold start.
    rm -f "$tmp/flock-calls" "$tmp/supervisor-started" "$tmp/clock"
    BUILDKIT_TEST_MODE=cold BUILDKIT_TEST_DELAY=0 BUILDKIT_TEST_CLOCK_STEP=30 sh "$tmp/helper"
    grep -F /tmp/sagent-buildx.lock "$tmp/flock-calls" >/dev/null
    # A stale socket is not readiness. Expire the startup deadline using
    # a fake clock, and retain the daemon's failure reason in stderr.
    rm -f "$tmp/flock-calls" "$tmp/supervisor-started" "$tmp/clock"
    printf 'daemon-startup-failed\n' > "$tmp/buildkit.log"
    rc=0
    BUILDKIT_TEST_MODE=down BUILDKIT_TEST_DELAY=0 sh "$tmp/helper" 2>"$tmp/err" || rc=$?
    [ "$rc" -eq 1 ]
    grep -F 'BuildKit did not become ready' "$tmp/err" >/dev/null
    grep -F daemon-startup-failed "$tmp/err" >/dev/null
    [ ! -e "$tmp/flock-calls" ]
    # The supervisor is asynchronous; give the stub time to record its start.
    for _ in $(seq 1 20); do [ -e "$tmp/supervisor-started" ] && break; sleep 0.05; done
    [ -e "$tmp/supervisor-started" ]
    printf '%s: healthy replies, slow cold startup and stale socket checks passed\n' "$(basename "$wrapper")"
done
