#!/usr/bin/env bash
# shellcheck disable=SC2016  # Expand command bodies inside the sandbox.
# Two live sandboxes share volumes, but must not share nested engine state.
set -euo pipefail
: "${ENGINE:?}" "${SUITE_IMG:?}"
name="sagent-concurrent-${SAGENT_VOLUME_SUFFIX#-}-$$"
home="$name-home"
store="$name-store"
first="$name-first"
second="$name-second"
third="$name-restart"
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        for container in "$first" "$second" "$third"; do
            "$ENGINE" logs "$container" >&2 2>/dev/null || true
            "$ENGINE" exec "$container" sh -c 'cat /tmp/sagent-container-storage.log /tmp/sagent-buildkit.log /tmp/sagent-docker-api.log' >&2 2>/dev/null || true
        done
    fi
    "$ENGINE" rm -f "$first" "$second" "$third" >/dev/null 2>&1 || true
    "$ENGINE" volume rm "$home" "$store" >/dev/null 2>&1 || true
}
trap cleanup EXIT
# New named volumes need only their mount roots assigned to the image user.
# shellcheck disable=SC2086
"$ENGINE" run --rm ${SAGENT_TEST_USERNS:-} --user root \
    -v "$home:/home/agent" -v "$store:/home/agent/.local/share/containers" \
    "$SUITE_IMG" sh -c 'chown "$(id -u agent):$(id -g agent)" /home/agent /home/agent/.local/share/containers'
start() {
    # shellcheck disable=SC2086
    "$ENGINE" run -d --name "$1" ${SAGENT_TEST_USERNS:-} \
        -v "$home:/home/agent" -v "$store:/home/agent/.local/share/containers" \
        -e SAGENT_STORAGE_WORKSPACE=/same/project \
        --device /dev/fuse --device /dev/net/tun \
        --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
        --security-opt label=disable --cap-drop=ALL \
        --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER --cap-add=FSETID \
        --cap-add=SETGID --cap-add=SETUID --cap-add=SYS_CHROOT --cap-add=NET_BIND_SERVICE \
        --pids-limit=512 --memory=2g --cpus=2 \
        --tmpfs /tmp:rw,nosuid,nodev,exec,size=256m \
        "$SUITE_IMG" sagent-run sleep infinity >/dev/null
}
ready() {
    "$ENGINE" exec "$1" sh -ec 'sagent-docker-api; sagent-buildkit; docker info >/dev/null'
}
# Start both before either is queried: this exercises first-use contention.
start "$first"
start "$second"
ready "$first"
ready "$second"
root1=$("$ENGINE" exec "$first" cat /run/sagent/storage-root)
root2=$("$ENGINE" exec "$second" cat /run/sagent/storage-root)
[ "$root1" != "$root2" ]
[ "${root1%/*}" = "${root2%/*}" ]
for container in "$first" "$second"; do
    root=$("$ENGINE" exec "$container" cat /run/sagent/storage-root)
    [ "$("$ENGINE" exec "$container" podman info --format '{{.Store.GraphRoot}}')" = "$root/storage-multiuser" ]
done
build_and_compose() {
    "$ENGINE" exec "$1" sh -ec '
        mkdir -p /tmp/concurrent-build
        cd /tmp/concurrent-build
        printf "%s\n" "$1" > marker
        printf "%s\n" "FROM public.ecr.aws/docker/library/alpine:3.22" "COPY marker /marker" > Dockerfile
        docker build -t concurrent-check .
        printf "%s\n" "services:" "  app:" "    image: concurrent-check" "    command: sleep 600" "    volumes: [data:/data]" "volumes:" "  data:" > compose.yml
        docker compose -p identical-project up -d
        docker compose -p identical-project exec -T app sh -ec "cat /marker > /data/marker"
        docker compose -p identical-project exec -T app cat /data/marker
    ' _ "$2"
}
build_and_compose "$first" first
build_and_compose "$second" second
check_marker() {
    [ "$("$ENGINE" exec "$1" sh -ec 'cd /tmp/concurrent-build; docker compose -p identical-project exec -T app cat /data/marker')" = "$2" ]
}
check_marker "$first" first
check_marker "$second" second
# Restart both daemons in the first sandbox. The storage reservation must
# survive this, and the second sandbox must keep its own service alive.
"$ENGINE" exec "$first" sh -ec 'pkill -x buildkitd; pkill -x podman'
ready "$first"
[ "$("$ENGINE" exec "$first" cat /run/sagent/storage-root)" = "$root1" ]
check_marker "$second" second
"$ENGINE" exec "$first" sh -ec 'cd /tmp/concurrent-build; docker compose -p identical-project down'
"$ENGINE" rm -f "$first" >/dev/null
start "$third"
ready "$third"
[ "$("$ENGINE" exec "$third" cat /run/sagent/storage-root)" = "$root1" ]
# Images and named-volume data survive reuse of the released slot.
[ "$("$ENGINE" exec "$third" docker run --rm concurrent-check cat /marker)" = first ]
[ "$("$ENGINE" exec "$third" docker run --rm -v identical-project_data:/data concurrent-check cat /data/marker)" = first ]
check_marker "$second" second
printf '%s\n' 'Concurrent builds, identical Compose projects, daemon restart and persistent slot reuse passed'
