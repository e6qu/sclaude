#!/usr/bin/env bash
# Run by T60 inside the sandbox, never directly on the host.
set -Eeuo pipefail
trap 'printf "Nested check failed at line %s (exit %s; pipeline %s): %s\n" "$LINENO" "$?" "${PIPESTATUS[*]}" "$BASH_COMMAND" >&2' ERR
work=$(mktemp -d /tmp/sagent-nested.XXXXXX)
cd "$work"
export COMPOSE_PROJECT_NAME=sagent-nested-check
ssh_pid=""
# A session can expire during slow VM I/O even though the build finishes
# its layers. Give this fixed CI fixture one fresh session using that cache.
# Also recover EOF after a new daemon SIGILL, retaining its crash report.
# Keep both attempts visible; RUN and capture failures remain failures.
build_nested_browser() {
    local log="$1" daemon_log="${2:-/tmp/sagent-buildkit.log}"
    local sigill_before sigill_after reason
    local -a status
    sigill_before=$(grep -c '^SIGILL: illegal instruction$' "$daemon_log" 2>/dev/null || true)
    if docker compose build browser 2>&1 | tee "$log"; then
        return 0
    else
        status=("${PIPESTATUS[@]}")
    fi
    [ "${status[1]}" -eq 0 ] || return "${status[1]}"
    if grep -Eq '^failed to solve: DeadlineExceeded: no active session for [^[:space:]]+: context deadline exceeded$' "$log"; then
        reason='lost its session'
    elif grep -Fxq 'failed to receive status: rpc error: code = Unavailable desc = error reading from server: EOF' "$log"; then
        sigill_after=$(grep -c '^SIGILL: illegal instruction$' "$daemon_log" 2>/dev/null || true)
        if [ -z "$sigill_after" ] || [ "$sigill_after" -le "${sigill_before:-0}" ]; then
            return "${status[0]}"
        fi
        reason='crashed with SIGILL'
        report_buildkit_failure "$daemon_log" >&2
    else
        return "${status[0]}"
    fi
    printf '\nBuildKit %s; retrying the browser fixture once with cached layers\n' "$reason" >&2
    docker compose build browser
}
# Keep the complete dump in the harness capture, then repeat a bounded
# summary at the end so CI's console tail retains the reason for the exit.
report_buildkit_failure() {
    local log="${1:-/tmp/sagent-buildkit.log}"
    local cgroup="${2:-/sys/fs/cgroup}"
    local counter
    if [ -r "$log" ]; then
        printf '\n=== Complete BuildKit daemon log ===\n'
        cat "$log"
    fi
    printf '\n=== Sandbox resource counters ===\n'
    for counter in pids.current pids.peak pids.max pids.events memory.current memory.peak memory.max memory.events; do
        if [ -r "$cgroup/$counter" ]; then
            printf '%s: ' "$counter"
            cat "$cgroup/$counter"
        fi
    done
    if [ -r "$log" ]; then
        printf '\n=== Latest BuildKit fatal error (first 40 lines) ===\n'
        awk '
            /^SIG[A-Z]+:|^panic:|^fatal error:|^runtime: (out of memory|failed to create new OS thread|goroutine stack exceeds)/ {
                if (!start || NR - start > 3) {
                    start = NR
                    count = 0
                }
            }
            start && count < 40 { lines[count++] = $0 }
            END { for (i = 0; i < count; i++) print lines[i] }
        ' "$log"
        printf '\n=== BuildKit daemon log tail ===\n'
        tail -n 15 "$log"
    fi
}
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        docker compose logs >&2 || true
        tail -n 10 /tmp/sagent-docker-api.log >&2 || true
        report_buildkit_failure /tmp/sagent-buildkit.log /sys/fs/cgroup >&2 || true
    fi
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    [ -z "$ssh_pid" ] || kill "$ssh_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# Native executables in the outer /tmp must work too (Podman's tmpfs default
# is noexec unless the wrapper explicitly supplies exec).
cp /bin/true ./exec-check
./exec-check

# A new ownership model must leave the previous store available for recovery.
legacy="$HOME/.local/share/containers/storage/volumes/legacy-check/_data"
mkdir -p "$legacy"
printf preserved > "$legacy/value"
# Complete lazy Podman initialization before reading the marker it creates.
graphroot=$(podman info --format "{{.Store.GraphRoot}}")
[ "$graphroot" = "$(cat /run/sagent/storage-root)/storage-multiuser" ]
# Consume the full output: quiet grep can close early and SIGPIPE Buildx
# while it is printing its remaining node details under pipefail.
docker buildx inspect --bootstrap | grep -E '^Driver: +remote$' >/dev/null
printf test-secret > token
export SSH_SOCKET="$work/ssh.sock"
ssh-agent -D -a "$SSH_SOCKET" >/dev/null 2>&1 &
ssh_pid=$!
for _ in $(seq 1 50); do [ -S "$SSH_SOCKET" ] && break; sleep 0.1; done
[ -S "$SSH_SOCKET" ]
cat > Dockerfile <<'DOCKERFILE'
FROM public.ecr.aws/docker/library/alpine:3.22 AS probe
RUN --mount=type=secret,id=token --mount=type=cache,target=/build-cache \
    test "$(cat /run/secrets/token)" = test-secret && echo cache-ok > /build-cache/value && echo buildkit-ok > /result
RUN --mount=type=cache,target=/build-cache test "$(cat /build-cache/value)" = cache-ok
RUN --mount=type=ssh,required=true test -S "$SSH_AUTH_SOCK"
USER 999:999
CMD ["cat", "/result"]

FROM public.ecr.aws/docker/library/python:3.13-slim-bookworm AS browser
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN --mount=type=cache,target=/root/.cache/pip pip install playwright==1.58.0
# apt must switch to _apt and keep multiple owners during package unpacking.
# This runs as root in the service image, so it does not need sudo.
RUN playwright install --with-deps --only-shell chromium && rm -rf /var/lib/apt/lists/*
COPY --from=probe /result /result
COPY browser.py /browser.py
USER 999:999
CMD ["python", "/browser.py"]
DOCKERFILE
cat > browser.py <<'PY'
import os
import shutil
import subprocess
from playwright.sync_api import sync_playwright

assert os.getuid() == 999
assert not os.path.exists('/run/secrets/token')
shutil.copy('/bin/true', '/tmp/exec-check')
subprocess.run(['/tmp/exec-check'], check=True)
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.goto('http://web:8080')
    assert 'sagent-web-ok' in page.text_content('body')
    browser.close()
print('playwright-ok')
PY
cat > compose.yml <<'COMPOSE'
services:
  db:
    image: public.ecr.aws/docker/library/postgres:17-bookworm
    environment:
      POSTGRES_PASSWORD: local-test-only
    volumes: [database:/var/lib/postgresql/data]
    healthcheck:
      test: [CMD-SHELL, "pg_isready -h 127.0.0.1 -U postgres"]
      interval: 1s
      timeout: 5s
      retries: 60
  web:
    image: sagent-playwright-check
    command: sh -c 'mkdir -p /tmp/www; echo sagent-web-ok > /tmp/www/index.html; python -m http.server 8080 --directory /tmp/www'
  browser:
    image: sagent-playwright-check
    build:
      context: .
      target: browser
      secrets: [token]
      ssh: ["default=${SSH_SOCKET}"]
    depends_on:
      web:
        condition: service_started
      db:
        condition: service_healthy
    tmpfs: ["/tmp:rw,nosuid,nodev,exec,size=256m"]
secrets:
  token:
    file: token
volumes:
  database:
COMPOSE

docker build --target probe --secret id=token,src=token --ssh "default=$SSH_SOCKET" -t sagent-build-check .
docker run --rm sagent-build-check | grep -x buildkit-ok >/dev/null
docker buildx build --target probe --secret id=token,src=token --ssh "default=$SSH_SOCKET" -t sagent-buildx-check .
docker run --rm sagent-buildx-check | grep -x buildkit-ok >/dev/null
docker buildx build --platform linux/amd64,linux/arm64 --target probe \
    --secret id=token,src=token --ssh "default=$SSH_SOCKET" \
    --output type=oci,dest="$work/multiarch.tar" .
tar -tf "$work/multiarch.tar" | grep -x index.json >/dev/null
build_nested_browser "$work/browser-build.log"
docker compose up -d --wait --wait-timeout 90 db web
docker compose exec -T --user root db sh -ec 'test "$(runuser -u _apt -- id -u)" = 42; apt-get update -qq'
docker compose exec -T db sh -c 'test "$(id -u postgres)" = 999'
docker compose exec -T db psql -U postgres -Atqc 'select 1' | grep -x 1 >/dev/null
docker compose run --rm browser | grep -x playwright-ok >/dev/null
[ "$(cat "$legacy/value")" = preserved ]
printf 'BuildKit, PostgreSQL and Playwright passed\n'
