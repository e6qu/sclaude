#!/usr/bin/env bash
# Probe the same container resolver nested Podman and BuildKit inherit.
set -euo pipefail

engine="${1:?container engine required}"
image="${2:?sandbox image required}"
expected_resolvers="${3:-}"
# shellcheck disable=SC2016 # hostname expands in the container's shell.
"$engine" run --rm "$image" bash -ec '
    cat /etc/resolv.conf
    for resolver in $1; do
        if ! awk '\''/^nameserver/ { print $2 }'\'' /etc/resolv.conf | grep -Fx "$resolver" > /dev/null; then
            printf "Expected container DNS resolver %s is missing\n" "$resolver" >&2
            exit 1
        fi
    done
    for hostname in public.ecr.aws registry.npmjs.org archive.ubuntu.com; do
        printf "Resolving %s\n" "$hostname"
        timeout 30 getent ahostsv4 "$hostname"
    done
' _ "$expected_resolvers"
