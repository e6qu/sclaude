#!/usr/bin/env bash
# Test that all devcontainer configurations build and run successfully.
# Requires: devcontainer CLI (npm install -g @devcontainers/cli)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

PASS=0
FAIL=0

# Track workspace folders that were started so we can clean up
STARTED_WORKSPACES=()

# shellcheck disable=SC2317,SC2329
cleanup_containers() {
    echo ""
    echo "[cleanup] Stopping devcontainers..."
    for ws in "${STARTED_WORKSPACES[@]+"${STARTED_WORKSPACES[@]}"}"; do
        # devcontainer CLI doesn't have a stop command; remove the container directly
        local label="devcontainer.local_folder=${ws}"
        docker ps -aq --filter "label=${label}" | while read -r cid; do
            docker rm -f "$cid" >/dev/null 2>&1 || true
        done
    done
}
trap cleanup_containers EXIT

run_test() {
    local name="$1"; shift
    printf "  %-55s " "$name"
    local output
    if output=$("$@" 2>&1); then
        printf "PASS\n"
        PASS=$((PASS + 1))
    else
        printf "FAIL\n"
        printf "    Output: %s\n" "${output:-(empty)}" | head -10
        FAIL=$((FAIL + 1))
    fi
}

# Check prerequisites
if ! command -v devcontainer >/dev/null 2>&1; then
    echo "ERROR: devcontainer CLI not found. Install with: npm install -g @devcontainers/cli" >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running" >&2
    exit 1
fi

echo "=== Devcontainer Tests ==="
echo "devcontainer CLI: $(devcontainer --version 2>/dev/null || echo 'unknown')"
echo ""

# ── Phase 1: Build all devcontainers ─────────────────────────────────
echo "--- Build ---"

run_test "build: sclaude-dev" \
    devcontainer build --workspace-folder "$SCRIPT_DIR"

run_test "build: devcontainer-claude" \
    devcontainer build --workspace-folder "$SCRIPT_DIR/examples/devcontainer-claude"

run_test "build: devcontainer-sclaude" \
    devcontainer build --workspace-folder "$SCRIPT_DIR/examples/devcontainer-sclaude"

# ── Phase 2: Start and smoke-test each devcontainer ──────────────────
echo ""
echo "--- Smoke tests ---"

# sclaude-dev: needs shellcheck, zsh, docker-in-docker
run_test "up: sclaude-dev" \
    devcontainer up --workspace-folder "$SCRIPT_DIR"
STARTED_WORKSPACES+=("$SCRIPT_DIR")

run_test "sclaude-dev: shellcheck available" \
    devcontainer exec --workspace-folder "$SCRIPT_DIR" shellcheck --version

run_test "sclaude-dev: zsh available" \
    devcontainer exec --workspace-folder "$SCRIPT_DIR" zsh --version

run_test "sclaude-dev: docker-in-docker works" \
    devcontainer exec --workspace-folder "$SCRIPT_DIR" docker version

# claude-code example: needs claude CLI
run_test "up: devcontainer-claude" \
    devcontainer up --workspace-folder "$SCRIPT_DIR/examples/devcontainer-claude"
STARTED_WORKSPACES+=("$SCRIPT_DIR/examples/devcontainer-claude")

run_test "devcontainer-claude: claude CLI installed" \
    devcontainer exec --workspace-folder "$SCRIPT_DIR/examples/devcontainer-claude" claude --version

run_test "devcontainer-claude: node available" \
    devcontainer exec --workspace-folder "$SCRIPT_DIR/examples/devcontainer-claude" node --version

# sclaude example: needs sclaude + docker-in-docker
run_test "up: devcontainer-sclaude" \
    devcontainer up --workspace-folder "$SCRIPT_DIR/examples/devcontainer-sclaude"
STARTED_WORKSPACES+=("$SCRIPT_DIR/examples/devcontainer-sclaude")

run_test "devcontainer-sclaude: sclaude installed" \
    devcontainer exec --workspace-folder "$SCRIPT_DIR/examples/devcontainer-sclaude" \
    bash -c "test -x /usr/local/bin/sclaude"

run_test "devcontainer-sclaude: docker-in-docker works" \
    devcontainer exec --workspace-folder "$SCRIPT_DIR/examples/devcontainer-sclaude" docker version

# ── Results ──────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
