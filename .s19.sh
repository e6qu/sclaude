#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single-quoted $1 is intentional (expands inside bash -c)
set -euo pipefail

# ── Resolve sclaude path ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCLAUDE="$SCRIPT_DIR/sclaude"
SCODEX="$SCRIPT_DIR/scodex"

if [ ! -x "$SCLAUDE" ]; then
    echo "ERROR: sclaude not found or not executable at $SCLAUDE" >&2
    exit 1
fi
if [ ! -x "$SCODEX" ]; then
    echo "ERROR: scodex not found or not executable at $SCODEX" >&2
    exit 1
fi

OS="$(uname -s)"
ENGINE="${SAGENT_CONTAINER_ENGINE:-docker}"
# Where tests create directories that get bind-mounted into containers. VM-backed
# engines only resolve paths under their shared mounts (Rancher Desktop shares
# just $HOME), so such jobs point this somewhere under the home directory.
SAGENT_TEST_TMPDIR="${SAGENT_TEST_TMPDIR:-/tmp}"
export SAGENT_TEST_TMPDIR
# Tests that replicate run_tool's bind mounts need the wrapper's rootless-podman
# user mapping too (#75); empty on every other engine.
SAGENT_TEST_USERNS=""
if [ "$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
    SAGENT_TEST_USERNS="--userns=keep-id:uid=$(id -u),gid=$(id -g)"
fi
export SAGENT_TEST_USERNS
export SAGENT_CONTAINER_ENGINE="$ENGINE"
export ENGINE

# shellcheck source=test_lib.sh disable=SC1091
. "$SCRIPT_DIR/test_lib.sh"

# ── Setup ─────────────────────────────────────────────────────────────
echo "=== sclaude E2E Tests ==="
echo "Platform: $OS ($(uname -m))"
echo "Engine:   $ENGINE ($("$ENGINE" --version 2>/dev/null || echo 'NOT FOUND'))"
echo "Bash:     ${BASH_VERSION}"
echo ""

# Ensure the selected container engine is running
INFO_OUTPUT=$(mktemp)
if ! run_with_timeout_capture "$INFO_OUTPUT" "$ENGINE" info; then
    cat "$INFO_OUTPUT" >&2
    rm -f "$INFO_OUTPUT"
    echo "ERROR: container engine is not running: $ENGINE" >&2
    exit 1
fi
rm -f "$INFO_OUTPUT"

# ── T32: generated Dockerfile and build-failure guidance ─────────────
# A stub engine records the build context and fails the build, so this checks
# (without a real build) that the CA block is emitted only when a bundle is
# configured, that the bundle is split one-certificate-per-file in the
# context, and that a failed build prints the proxy-CA guidance.
run_test "T32: Dockerfile generation and build guidance" bash -ec '
    set -e
    tmp=$(mktemp -d /tmp/sagent-t32.XXXXXX)
    trap "rm -rf \"$tmp\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) exit 0 ;;
    version) printf "Client: Docker Engine\nServer: Docker Engine\n"; exit 0 ;;
    run) cat >/dev/null; echo TLS-OK; exit 0 ;;
    build)
        for last; do :; done
        cp "\$last/Dockerfile" "$tmp/Dockerfile"
        (cd "\$last" && find . -type f | sort) > "$tmp/context.txt"
        exit 1 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    # Defaults only: no user or CI config file may shape the Dockerfile this
    # test inspects.
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONTAINER_ENGINE="$tmp/fake-engine" SAGENT_CONFIG_FILE="$tmp/no-config"

    if "$1" --build >"$tmp/out" 2>&1; then
        echo "build should have failed with the stub engine" >&2
        exit 1
    fi
    grep -q "sandbox image build failed" "$tmp/out"
    grep -q "TLS interception was checked before the build" "$tmp/out"
    if grep -q "sagent-ca" "$tmp/Dockerfile"; then
        echo "CA block emitted without SAGENT_CA_BUNDLE" >&2
        exit 1
    fi
    grep -q "apt-get install -y gh" "$tmp/Dockerfile"
    [ "$(cat "$tmp/context.txt")" = "./Dockerfile" ]
    # Toolchain versions reach the Dockerfile as FROM/ARG values.
    tc=$(SAGENT_SKIP_RELEASE_CHECK=1 "$1" version | sed -n "s/^Toolchain: //p")
    grep -q "^FROM ubuntu:$(echo "$tc" | sed "s/.*ubuntu=\([^ ]*\).*/\1/")\$" "$tmp/Dockerfile"
    grep -q "^ARG NODE_VERSION=$(echo "$tc" | sed "s/.*node=\([^ ]*\).*/\1/")\$" "$tmp/Dockerfile"
    grep -q "go.dev/dl" "$tmp/Dockerfile"
    grep -q "sh.rustup.rs" "$tmp/Dockerfile"
    grep -q "api.adoptium.net" "$tmp/Dockerfile"
    # "none" leaves a toolchain out of the image entirely.
    SAGENT_GO_VERSION=none SAGENT_RUST_VERSION=none SAGENT_JAVA_VERSION=none "$1" --build >/dev/null 2>&1 || true
    if grep -qE "go.dev/dl|sh.rustup.rs|api.adoptium.net|JAVA_HOME|RUSTUP_HOME" "$tmp/Dockerfile"; then
        echo "toolchain blocks emitted despite =none" >&2
        exit 1
    fi
    grep -q "^ARG GO_VERSION=none\$" "$tmp/Dockerfile"
    # SAGENT_TOOLS=none: only the agent CLIs are installed, in their own
    # last layer; no JS tooling layer at all.
    SAGENT_TOOLS=none "$1" --build >/dev/null 2>&1 || true
    grep -q "npm install -g @anthropic-ai/claude-code @openai/codex\$" "$tmp/Dockerfile"
    if grep -qE "^RUN npm install -g " "$tmp/Dockerfile"; then
        echo "a JS tooling layer was emitted despite SAGENT_TOOLS=none" >&2
        exit 1
    fi
    if grep -qE "corepack enable|apache-maven|gradle.zip|quarkus-cli|spring-boot-cli" "$tmp/Dockerfile"; then
        echo "tooling emitted despite SAGENT_TOOLS=none" >&2
        exit 1
    fi
    # A subset: named tools and nothing else.
    SAGENT_TOOLS="bun,maven" "$1" --build >/dev/null 2>&1 || true
    # The selected JS tooling is its own layer; the agent CLIs are the last
    # one, so a CLI release does not rebuild everything after them.
    grep -q "^RUN npm install -g bun\$" "$tmp/Dockerfile"
    grep -q "npm install -g @anthropic-ai/claude-code @openai/codex\$" "$tmp/Dockerfile"
    grep -q "apache-maven" "$tmp/Dockerfile"
    if grep -qE "corepack enable|gradle.zip|quarkus-cli|spring-boot-cli" "$tmp/Dockerfile"; then
        echo "unselected tooling emitted" >&2
        exit 1
    fi

    for n in 1 2 3; do
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=sagent-t32-ca$n" \
            -keyout "$tmp/ca$n.key" -out "$tmp/ca$n.pem" >/dev/null 2>&1
    done
    cat "$tmp/ca1.pem" "$tmp/ca2.pem" "$tmp/ca3.pem" > "$tmp/bundle.pem"
    if SAGENT_CA_BUNDLE="$tmp/bundle.pem" "$1" --build >"$tmp/out" 2>&1; then
        echo "build should have failed with the stub engine" >&2
        exit 1
    fi
    grep -q "Baking 3 CA certificate(s)" "$tmp/out"
    grep -q "with SAGENT_CA_BUNDLE=.*(3 certificate(s))" "$tmp/out"
    # the CA block precedes the first HTTPS fetch (the gh keyring download)
    ca_line=$(grep -n "^COPY sagent-ca/" "$tmp/Dockerfile" | cut -d: -f1)
    gh_line=$(grep -n "cli.github.com" "$tmp/Dockerfile" | head -1 | cut -d: -f1)
    [ "$ca_line" -lt "$gh_line" ]
    grep -q "^RUN update-ca-certificates" "$tmp/Dockerfile"
    grep -q "^ENV NODE_EXTRA_CA_CERTS=/usr/local/share/sagent-ca-bundle.pem" "$tmp/Dockerfile"
    printf "%s\n" ./Dockerfile ./sagent-ca-bundle.pem ./sagent-ca/sagent-001.crt ./sagent-ca/sagent-002.crt ./sagent-ca/sagent-003.crt \
        | diff - "$tmp/context.txt"
' _ "$SCLAUDE"

print_results
