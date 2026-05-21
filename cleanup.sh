#!/usr/bin/env bash
# Cleanup helper for recovering local disk space and Podman/Docker state.
# macOS-only: references ~/.Trash and the Apple Hypervisor Podman machine path.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "cleanup.sh: macOS only (references ~/.Trash and applehv machine paths)" >&2
    exit 1
fi

confirm() {
    local prompt="$1"
    printf "%s [y/N] " "$prompt"
    read -r answer
    case "$answer" in
        y|Y|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

show_disk() {
    echo ""
    echo "Disk usage:"
    df -h /Users /private/tmp 2>/dev/null || df -h
}

echo "This script can delete local Trash contents, known temporary caches,"
echo "failed sclaude-test Podman machine artifacts, and optionally prune"
echo "Docker/Podman images, containers, build cache, networks, and volumes."
echo ""
echo "Current candidates:"
du -sh "$HOME/.Trash" 2>/dev/null || true
du -sh /private/tmp/sockerless-go-cache /private/tmp/sockerless-gocache 2>/dev/null || true
du -sh "$HOME"/.local/share/containers/podman/machine/applehv/sclaude-test-*.raw 2>/dev/null || true
show_disk

if confirm "Delete Trash contents and known temporary sockerless caches?"; then
    if [ -d "$HOME/.Trash" ]; then
        find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    rm -rf /private/tmp/sockerless-go-cache /private/tmp/sockerless-gocache
fi

if confirm "Remove failed sclaude-test Podman machine artifacts if present?"; then
    pkill -f "podman machine init.*sclaude-test" 2>/dev/null || true
    podman machine rm -f sclaude-test 2>/dev/null || true
    rm -f "$HOME"/.local/share/containers/podman/machine/applehv/sclaude-test-*.raw
fi

if confirm "Restart existing podman-machine-default?"; then
    podman machine stop podman-machine-default 2>/dev/null || true
    pkill -f "gvproxy.*podman-machine-default" 2>/dev/null || true
    pkill -f "vfkit.*podman-machine-default" 2>/dev/null || true
    podman machine start podman-machine-default
fi

echo ""
echo "Runtime status:"
podman machine list 2>/dev/null || true
podman info >/dev/null 2>&1 && echo "podman info: OK" || echo "podman info: FAILED"
docker info >/dev/null 2>&1 && echo "docker info: OK" || echo "docker info: FAILED"

if confirm "Run destructive docker system prune -af --volumes?"; then
    docker system prune -af --volumes
fi

if confirm "Run destructive podman system prune -af --volumes?"; then
    podman system prune -af --volumes
fi

show_disk
echo ""
echo "Final runtime status:"
podman machine list 2>/dev/null || true
podman info >/dev/null 2>&1 && echo "podman info: OK" || echo "podman info: FAILED"
docker info >/dev/null 2>&1 && echo "docker info: OK" || echo "docker info: FAILED"
