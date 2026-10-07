#!/usr/bin/env bash
# Exercise session startup and Docker dispatch without starting an engine.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -eq 0 ]; then set -- "$SCRIPT_DIR/sclaude" "$SCRIPT_DIR/scodex"; fi
tmp=$(mktemp -d /tmp/sagent-sessions-test.XXXXXX)
sandbox=""
cleanup() {
    if [ -n "$sandbox" ]; then "$ENGINE" rm -f "$sandbox" >/dev/null 2>&1 || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT
mkdir "$tmp/drop"
export SESSION_TEST_ROOT="$tmp"
cat > "$tmp/config-engine" <<'SH'
#!/bin/sh
case "$1" in
    info) printf '8 17179869184 name=seccomp,profile=default\n' ;;
    version) printf 'Client: Docker Engine\nServer: Docker Engine\n' ;;
    run) printf '%s\n' "$@" > "$SESSION_TEST_ROOT/launch" ;;
esac
SH
chmod +x "$tmp/config-engine"
for name in sagent-docker-api sagent-buildkit docker; do
    cat > "$tmp/$name" <<'SH'
#!/bin/sh
printf '%s\n' "${0##*/}:$*" >> "$SESSION_TEST_ROOT/calls"
SH
    chmod +x "$tmp/$name"
done
for wrapper in "$@"; do
    # Execute the whole wrapper: defaults and settings must reach the engine.
    for nested in 1 0; do
        for settings in default custom; do
            : > "$tmp/config"
            expected=4096
            if [ "$settings" = custom ]; then
                printf 'PIDS_LIMIT=73\nPIDS_LIMIT_NESTED=911\n' > "$tmp/config"
                if [ "$nested" = 1 ]; then expected=911; else expected=73; fi
            fi
            SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/config-engine" \
                SAGENT_CONFIG_FILE="$tmp/config" SAGENT_DOCKER="$nested" \
                SAGENT_CLIPBOARD=0 SAGENT_SESSIONS=0 SAGENT_DROP_DIR="$tmp/drop" \
                "$wrapper" --help > "$tmp/out" 2> "$tmp/err" || { cat "$tmp/err" >&2; exit 1; }
            if ! grep -Fx -- "--pids-limit=$expected" "$tmp/launch" >/dev/null; then
                printf '%s: wrong process limit for nested=%s settings=%s; expected %s\n' \
                    "$wrapper" "$nested" "$settings" "$expected" >&2
                cat "$tmp/launch" >&2
                exit 1
            fi
            grep -Fx nproc=-1:-1 "$tmp/launch" >/dev/null
        done
    done
    python3 - "$wrapper" "$tmp" <<'PYTHON'
import pathlib
import subprocess
import sys

source = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
for name in ['docker', 'sagent-run']:
    end = source.index('        > /usr/local/bin/' + name + ';')
    start = source.rfind("    printf '%s\\n' \\", 0, end)
    assert start >= 0
    block = source[start:end].rstrip()
    helper = subprocess.check_output(['bash', '-c', block[:-1] + '\n']).decode()
    helper = helper.replace('[ -c /dev/fuse ]', 'true')
    helper = helper.replace('[ ! -c /dev/fuse ]', 'false')
    for command in ['sagent-docker-api', 'sagent-buildkit']:
        helper = helper.replace('/usr/local/bin/' + command, str(root / command))
    helper = helper.replace('/usr/bin/docker', str(root / 'docker'))
    (root / (name + '-helper')).write_text(helper)
PYTHON
    : > "$tmp/calls"
    rc=0
    env -u DISPLAY bash "$tmp/sagent-run-helper" sh -c 'exit 37' || rc=$?
    [ "$rc" = 37 ]
    grep -Fx 'sagent-docker-api:' "$tmp/calls" >/dev/null
    if grep -F sagent-buildkit "$tmp/calls" >/dev/null; then
        echo 'session startup eagerly starts BuildKit' >&2; exit 1
    fi
    check() {
        expected="$1"; shift
        : > "$tmp/calls"
        sh "$tmp/docker-helper" "$@"
        grep -Fx 'sagent-docker-api:' "$tmp/calls" >/dev/null
        grep -Fx "docker:$*" "$tmp/calls" >/dev/null
        if [ "$expected" = build ]; then
            grep -Fx 'sagent-buildkit:' "$tmp/calls" >/dev/null
        elif grep -F sagent-buildkit "$tmp/calls" >/dev/null; then
            echo "non-build command starts BuildKit: $*" >&2; exit 1
        fi
    }
    check api ps
    check api image ls
    check api run --name build alpine echo compose
    check api --context build info
    check api --config /tmp/config -H unix:///run/podman/podman.sock ps
    check api --context=build --debug version
    check build build -t example .
    check build image build -t example .
    check build buildx build --load .
    check build builder prune
    check build --context local --debug compose up -d
    check build --config /tmp/config compose build
    # Invoke the real launch function with an engine that records argv.
    sed -n '/^run_tool()/,/^}/p' "$wrapper" > "$tmp/run-tool"
    cat > "$tmp/engine" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$SESSION_TEST_ROOT/launch"
SH
    chmod +x "$tmp/engine"
    for nested in true false; do
        bash -euo pipefail -c '
            . "$1"
            ENGINE_CMD="$2"
            DOCKER_TOOLING="$3"
            start_clipboard_bridge() { :; }
            stop_clipboard_bridge() { :; }
            build_session_mount_args() { :; }
            WORKSPACE_PATH=/workspace WORKSPACE_HOST_PATH=/workspace
            PIDS_LIMIT=100 PIDS_LIMIT_NESTED=512 YOLO=false
            NO_YOLO_SUBCOMMANDS="" ARGS=(-c true) DROP_DIR=""
            EXTRA_MOUNT_DIRS=(/extra) EXTRA_MOUNT_HOST_DIRS=(/extra)
            EXTRA_MOUNT_MODES=(ro) DOCKER_TTY_FLAGS=(-i)
            EFFECTIVE_MEMORY_LIMIT=8g EFFECTIVE_CPU_LIMIT=2
            CONFIG_VOLUME=config CONFIG_MOUNT=/config CONFIG_ENV_NAME=TEST_CONFIG
            ROOTFS_VOLUME=home NPM_VOLUME=npm PIP_VOLUME=pip SHARE_VOLUME=share
            CONTAINERS_VOLUME=containers APT_CACHE_VOLUME=apt APT_LISTS_VOLUME=lists
            SCRIPT_NAME=test IMAGE_NAME=test TOOL_BIN=bash
            run_tool
        ' _ "$tmp/run-tool" "$tmp/engine" "$nested"
        grep -Fx nproc=-1:-1 "$tmp/launch" >/dev/null
        if [ "$nested" = true ]; then limit=512; else limit=100; fi
        grep -Fx -- "--pids-limit=$limit" "$tmp/launch" >/dev/null
    done
    printf '%s: lazy BuildKit, Docker argument forwarding and bounded session launch passed\n' "$(basename "$wrapper")"
done

# In E2E, check actual orphan adoption/reaping under a small cgroup limit.
# Each short-lived tool leaves a grandchild behind, like detached test servers
# and unsuccessful background flock attempts. No services/images are pulled.
if [ -n "${ENGINE:-}" ] && [ -n "${SUITE_IMG:-}" ]; then
    # shellcheck disable=SC2086
    "$ENGINE" run --rm ${SAGENT_TEST_USERNS:-} \
        --pids-limit=64 --ulimit nproc=-1:-1 "$SUITE_IMG" python3 -c '
import os
import pathlib
import time

assert pathlib.Path("/proc/1/comm").read_text().strip() == "tini", "image init is not PID 1"

for _ in range(256):
    child = os.fork()
    if child == 0:
        if os.fork() == 0:
            time.sleep(0.002)
        os._exit(0)
    _, status = os.waitpid(child, 0)
    assert os.waitstatus_to_exitcode(status) == 0, "tool could not fork"
    time.sleep(0.002)

def zombies():
    found = []
    for status in pathlib.Path("/proc").glob("[0-9]*/status"):
        try:
            if "State:\tZ" in status.read_text():
                found.append(str(status))
        except FileNotFoundError:
            pass
    return found

for _ in range(100):
    time.sleep(0.02)
    if not zombies():
        break
else:
    raise RuntimeError("init did not reap orphaned children: " + str(zombies()))
print("256 orphaned tool children reaped within a 64-task budget")
'
    # The image's init must preserve the tool's status and forward stop signals.
    # No --init flag: these checks exercise the shipped image entrypoint.
    status=0
    # shellcheck disable=SC2086
    "$ENGINE" run --rm ${SAGENT_TEST_USERNS:-} --pids-limit=64 --ulimit nproc=-1:-1 \
        "$SUITE_IMG" python3 -c 'raise SystemExit(37)' || status=$?
    [ "$status" = 37 ] || { echo "init lost child exit status: $status" >&2; exit 1; }
    # shellcheck disable=SC2086
    sandbox=$("$ENGINE" run -d ${SAGENT_TEST_USERNS:-} --pids-limit=64 --ulimit nproc=-1:-1 \
        "$SUITE_IMG" python3 -u -c '
import signal
import time

def stop(_signal, _frame):
    raise SystemExit(42)

signal.signal(signal.SIGTERM, stop)
print("init-child-ready")
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    time.sleep(0.1)
raise SystemExit(64)
')
    ready=false
    for _ in $(seq 1 100); do
        if "$ENGINE" logs "$sandbox" 2>/dev/null | grep -Fx init-child-ready >/dev/null; then
            ready=true; break
        fi
        sleep 0.1
    done
    [ "$ready" = true ] || { echo 'init signal test child did not start' >&2; exit 1; }
    "$ENGINE" stop --time 5 "$sandbox" >/dev/null
    status=$("$ENGINE" inspect --format '{{.State.ExitCode}}' "$sandbox")
    [ "$status" = 42 ] || { echo "init did not forward SIGTERM: $status" >&2; exit 1; }
    "$ENGINE" rm "$sandbox" >/dev/null
    sandbox=""
    printf 'image init preserves child status and forwards SIGTERM\n'
fi
