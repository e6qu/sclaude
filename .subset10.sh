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

SUITE_IMG="sagent-sandbox:1758f3bc"; export SUITE_IMG
# ── T19b: clipboard shims, git defaults and locale in the image ──────
run_test "T19b: image clipboard shims, git defaults, locale" bash -ec '
    "$ENGINE" run --rm -i "$SUITE_IMG" bash -s <<"EOF"
set -e
[ "$LANG" = C.UTF-8 ]
for n in pbcopy pbpaste wl-copy wl-paste xclip xsel; do
    [ "$(readlink -f "$(command -v $n)")" = /usr/local/bin/host-clipboard ] || { echo "$n is not the clipboard shim" >&2; exit 1; }
done
# Copy emits OSC 52 with the base64 payload, ESC-backslash terminated (to stderr without a tty).
out=$(printf hello | pbcopy 2>&1)
[ "$out" = "$(printf "\033]52;c;aGVsbG8=\033\\\\")" ]
printf hello | xclip -selection clipboard 2>&1 | grep -q "52;c;aGVsbG8="
# Without the bridge, reads fail loudly and print nothing on stdout.
for c in pbpaste wl-paste "xclip -selection clipboard -t TARGETS -o" "xsel --clipboard --output"; do
    out=$($c 2>/dev/null) && { echo "$c should fail" >&2; exit 1; }
    [ -z "$out" ]
    $c 2>&1 | grep -q "no clipboard bridge"
done
[ "$(git config --system --get credential.https://github.com.helper)" = "!gh auth git-credential" ]
! git config --system --get-all url.https://github.com/.insteadof
git lfs version | grep -q "^git-lfs/"
[ "$(git config --system --get filter.lfs.required)" = true ]
EOF
' _ "$SCLAUDE"

# ── T19c: clipboard bridge round trip ────────────────────────────────
# The wrapper's clipboard agent (host side, sourced from the wrapper) serves
# the sandbox's clipboard shims through a bind-mounted directory. A fake
# host clipboard (pbcopy/pbpaste/osascript on macOS, xclip under DISPLAY on
# Linux) records what the agent does, so this runs on headless CI too.
run_test "T19c: clipboard bridge round trip" bash -ec '
    TMP=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t19c.XXXXXX")
    AGENT=""
    trap "kill \$AGENT 2>/dev/null || true; rm -rf \"$TMP\"" EXIT
    mkdir -p "$TMP/bin" "$TMP/bridge"
    printf "png-bytes" > "$TMP/image.png"
    cat > "$TMP/bin/pbcopy" <<EOF
#!/bin/sh
cat > "$TMP/clip.txt"
EOF
    cat > "$TMP/bin/pbpaste" <<EOF
#!/bin/sh
cat "$TMP/clip.txt"
EOF
    cat > "$TMP/bin/osascript" <<EOF
#!/bin/sh
case "\$*" in
    *"clipboard info"*) echo "«class PNGf», 9, string, 4" ;;
    *PNGf*) out=\$(printf "%s\\n" "\$@" | sed -n "s/.*POSIX file \"\\(.*\\)\" with.*/\\1/p"); cp "$TMP/image.png" "\$out" ;;
esac
EOF
    cat > "$TMP/bin/xclip" <<EOF
#!/bin/sh
target=UTF8_STRING; out=0
while [ \$# -gt 0 ]; do case "\$1" in -t) target=\$2; shift ;; -o) out=1 ;; esac; shift; done
if [ \$out = 0 ]; then cat > "$TMP/clip.txt"; exit 0; fi
case "\$target" in
    TARGETS) printf "TARGETS\\nimage/png\\ntext/plain\\n" ;;
    image/png) cat "$TMP/image.png" ;;
    *) cat "$TMP/clip.txt" ;;
esac
EOF
    chmod +x "$TMP"/bin/*
    export PATH="$TMP/bin:$PATH" DISPLAY=:9
    unset WAYLAND_DISPLAY
    printf "from-host" > "$TMP/clip.txt"
    # The agent, straight from the wrapper.
    sed -n "/^# ---- Clipboard bridge/,/^# ---- End clipboard bridge/p" "$1" > "$TMP/bridge.sh"
    bash -c ". \"$TMP/bridge.sh\"; clipboard_bridge_serve \"$TMP/bridge\"" &
    AGENT=$!
    BRIDGE_HOST=$(cd "$TMP/bridge" && pwd -P)
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v "$BRIDGE_HOST:/run/sagent/clipboard:rw" "$SUITE_IMG" bash -ec "
        [ \"\$(pbpaste)\" = from-host ]
        [ \"\$(wl-paste --no-newline)\" = from-host ]
        [ \"\$(xclip -selection clipboard -o)\" = from-host ]
        xclip -selection clipboard -t TARGETS -o | grep -q image/png
        wl-paste -l | grep -q image/png
        [ \"\$(xclip -selection clipboard -t image/png -o)\" = png-bytes ]
        [ \"\$(wl-paste --type image/png)\" = png-bytes ]
        ! xclip -selection clipboard -t image/bmp -o 2>/dev/null
        printf to-host | pbcopy
        printf to-host-2 | wl-copy
        printf to-host-3 | xclip -selection clipboard
        printf to-host-4 | xsel --clipboard --input
        [ \"\$(ls -A /run/sagent/clipboard)\" = \"\" ]
    "
    [ "$(cat "$TMP/clip.txt")" = to-host-4 ]
    # A request nobody answers fails loudly instead of hanging.
    kill "$AGENT"; wait "$AGENT" 2>/dev/null || true
    "$ENGINE" run --rm $SAGENT_TEST_USERNS -v "$BRIDGE_HOST:/run/sagent/clipboard:rw" "$SUITE_IMG" bash -ec "
        ! pbpaste 2>\"/tmp/err\"
        grep -q \"did not answer\" /tmp/err
    "
' _ "$SCLAUDE"

# ── T20a: host git config, gh login and SSH sync ─────────────────────
# The wrapper carries the host's global git config (minus host-only keys)
# and gh login into the home volume on every run. GIT_CONFIG_GLOBAL and
# GH_CONFIG_DIR point git and a fake gh at synthetic state; XDG_CONFIG_HOME
# stays untouched because the wrapper's own config file lives there and CI
# slims the image through it. The volume is inspected as root: on rootless
# podman the image's user maps to a subordinate UID and cannot read the
# 600-mode hosts.yml.
run_test "T20a: host git config, gh login and SSH sync" bash -ec '
    TMP=$(mktemp -d)
    trap "rm -rf \"$TMP\"" EXIT
    mkdir -p "$TMP/bin" "$TMP/gh"
    printf "*.swp\n" > "$TMP/ignore"
    cat > "$TMP/gitconfig" <<EOF
[user]
	name = Sync Test
	email = sync@example.com
	signingkey = ABCDEF
[commit]
	gpgsign = true
[credential]
	helper = osxkeychain
[core]
	editor = code --wait
	excludesfile = $TMP/ignore
[alias]
	st = status --short
[safe]
	directory = /a
	directory = /b
EOF
    cat > "$TMP/gh/hosts.yml" <<EOF
github.com:
    git_protocol: ssh
    user: alice
ghe.example.com:
    user: bob
EOF
    cat > "$TMP/bin/gh" <<EOF
#!/bin/sh
[ -n "\${GH_TOKEN:-}" ] && { echo LEAKED_ENV_TOKEN; exit 0; }
case "\$4" in
    github.com) echo gho_synctest ;;
    ghe.example.com) echo ghp_ghetoken ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TMP/bin/gh"
    PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GH_CONFIG_DIR="$TMP/gh" GH_TOKEN=envtoken \
        SAGENT_GIT_PROTOCOL=https SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo --help >/dev/null
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        cfg=/h/.config/git/config
        [ \"\$(git config --file \$cfg --get user.name)\" = \"Sync Test\" ]
        [ \"\$(git config --file \$cfg --get alias.st)\" = \"status --short\" ]
        [ \"\$(git config --file \$cfg --get-all safe.directory | wc -l)\" -eq 2 ]
        for k in user.signingkey commit.gpgsign credential.helper core.editor core.excludesfile; do
            if git config --file \$cfg --get \$k >/dev/null; then echo \"host-only key synced: \$k\" >&2; exit 1; fi
        done
        [ \"\$(git config --file \$cfg --get credential.https://ghe.example.com.helper)\" = \"!gh auth git-credential\" ]
        git config --file \$cfg --get-all url.https://ghe.example.com/.insteadof | grep -qx \"git@ghe.example.com:\"
        git config --file \$cfg --get-all url.https://github.com/.insteadof | grep -qx \"ssh://git@github.com/\"
        [ ! -e /h/.ssh/.sagent-synced ]
        grep -qx \"*.swp\" /h/.config/git/ignore
        [ -e /h/.gitconfig ]
        grep -q gho_synctest /h/.config/gh/hosts.yml
        grep -q ghp_ghetoken /h/.config/gh/hosts.yml
        grep -q \"user: alice\" /h/.config/gh/hosts.yml
        grep -q \"git_protocol: https\" /h/.config/gh/hosts.yml
        ! grep -q LEAKED_ENV_TOKEN /h/.config/gh/hosts.yml
        [ \"\$(stat -c %a /h/.config/gh/hosts.yml)\" = 600 ]
    "
    # The synced git files mirror the host: gone from the host, gone from the
    # volume. An excludes file that no longer exists stands in for "none"
    # (the default ~/.config/git/ignore may exist on the machine running this).
    # Unset, the protocol follows the host gh (ssh in this hosts.yml): no
    # rewrite, and ~/.ssh is synced by manifest with a sandbox-made key left
    # alone. Back on https the manifest'"'"'s files go and that key stays.
    printf "[core]\n\texcludesfile = %s\n" "$TMP/missing" > "$TMP/gitconfig2"
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        mkdir -p /h/.ssh && echo sandbox-key > /h/.ssh/id_sandbox
    "
    # The sync mirrors ~/.ssh only when it exists; a CI runner may have none.
    if [ ! -d ~/.ssh ]; then mkdir -m 700 ~/.ssh; fi
    PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig2" GH_CONFIG_DIR="$TMP/gh" \
        SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo --help >/dev/null
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        ! git config --file /h/.config/git/config --get user.name
        [ ! -e /h/.config/git/ignore ]
        grep -q \"git_protocol: ssh\" /h/.config/gh/hosts.yml
        ! git config --file /h/.config/git/config --get-all url.https://github.com/.insteadof
        [ -f /h/.ssh/.sagent-synced ]
        [ \"\$(stat -c %a /h/.ssh)\" = 700 ]
        while IFS= read -r f; do
            [ -f \"/h/.ssh/\$f\" ] && [ \"\$(stat -c %a \"/h/.ssh/\$f\")\" = 600 ] || { echo \"synced ssh file wrong: \$f\" >&2; exit 1; }
        done < /h/.ssh/.sagent-synced
        [ -f /h/.ssh/id_sandbox ]
    "
    PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig2" GH_CONFIG_DIR="$TMP/gh" \
        SAGENT_GIT_PROTOCOL=https SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo --help >/dev/null
    "$ENGINE" run --rm --user root -v sagent-rootfs:/h "$SUITE_IMG" bash -ec "
        [ ! -e /h/.ssh/.sagent-synced ]
        [ -f /h/.ssh/id_sandbox ]
        [ \"\$(ls -A /h/.ssh | wc -l)\" -eq 1 ]
        rm -f /h/.ssh/id_sandbox
    "
' _ "$SCLAUDE"

# ── T20: Codex config sync ───────────────────────────────────────────
run_test "T20: scodex config sync" bash -ec '
    TMP_CODEX_HOME=$(mktemp -d)
    trap "rm -rf \"$TMP_CODEX_HOME\"" EXIT
    printf "%s" "{\"test_codex_auth\":true}" > "$TMP_CODEX_HOME/auth.json"
    printf "%s\n" "model = \"gpt-5\"" > "$TMP_CODEX_HOME/config.toml"
    "$ENGINE" volume rm scodex-config >/dev/null 2>&1 || true
    CODEX_HOME="$TMP_CODEX_HOME" SAGENT_SKIP_RELEASE_CHECK=1 "$1" --no-yolo exec --help >/dev/null
    "$ENGINE" run --rm -v scodex-config:/c alpine cat /c/auth.json 2>/dev/null | grep -q test_codex_auth
    "$ENGINE" run --rm -v scodex-config:/c alpine cat /c/config.toml 2>/dev/null | grep -q "model"
' _ "$SCODEX"

# ── T24: wrapper parity ──────────────────────────────────────────────
# sclaude and scodex share their sandbox implementation; only the tool-specific
# functions may differ. Any drift in a shared function is a bug. Functions are
# auto-discovered from sclaude, so new shared functions are covered without
# updating this test. Script-name mentions in comments are normalized.
run_test "T24: wrapper shared functions identical" bash -ec '
    tmpdir=$(mktemp -d)
    trap "rm -rf \"$tmpdir\"" EXIT
    divergent="read_credentials sync_state run_tool"
    rc=0
    for fn in $(grep -oE "^[a-z_0-9]+\(\)" "$1" | tr -d "()"); do
        case " $divergent " in *" $fn "*) continue ;; esac
        for f in "$1" "$2"; do
            awk -v fn="$fn" "\$0 ~ \"^\"fn\"\\\\(\\\\) {\" {inf=1} inf {print} inf && /^}/ {inf=0}" "$f" \
                | sed "s/scodex/sclaude/g" > "$tmpdir/$(basename "$f").fn"
        done
        if ! diff -u "$tmpdir/$(basename "$1").fn" "$tmpdir/$(basename "$2").fn"; then
            echo "Shared function diverges between wrappers: $fn" >&2
            rc=1
        fi
    done
    # The main dispatch after the function definitions is shared too.
    for f in "$1" "$2"; do
        sed -n "/^parse_args \"\$@\"/,\$p" "$f" | sed "s/scodex/sclaude/g" > "$tmpdir/$(basename "$f").tail"
    done
    if ! diff -u "$tmpdir/$(basename "$1").tail" "$tmpdir/$(basename "$2").tail"; then
        echo "Main dispatch diverges between wrappers" >&2
        rc=1
    fi
    exit "$rc"
' _ "$SCLAUDE" "$SCODEX"

# ── T38: tools and config commands edit the text config ──────────────
run_test "T38: tools/config commands" bash -ec '
    cfg=$(mktemp -d /tmp/sagent-t38.XXXXXX)
    trap "rm -rf \"$cfg\"" EXIT
    export SAGENT_SKIP_RELEASE_CHECK=1 SAGENT_CONFIG_FILE="$cfg/config"
    base=$("$1" version | sed -n "s/^Image hash: //p")
    "$1" tools | grep -qE "^  bun +js +included"
    "$1" tools disable bun gradle 2>/dev/null
    grep -qx "SAGENT_TOOLS=\"typescript,tsx,corepack,create-next-app,create-vite,shadcn,maven,quarkus,spring\"" "$cfg/config"
    "$1" tools | grep -qE "^  bun +js +excluded"
    "$1" version | grep -q "^Tools: typescript tsx corepack create-next-app create-vite shadcn maven quarkus spring$"
    [ "$("$1" version | sed -n "s/^Image hash: //p")" != "$base" ]
    "$1" tools enable java 2>/dev/null
    "$1" version | grep -q "^Tools: .* maven gradle quarkus spring$"
    "$1" tools disable all 2>/dev/null
    "$1" version | grep -q "^Tools: none$"
    if "$1" tools enable no-such-tool >/dev/null 2>&1; then echo "unknown tool accepted" >&2; exit 1; fi
    # config: set, get, list, unset, validation, unknown keys
    "$1" config set SAGENT_NODE_VERSION 24 2>/dev/null
    "$1" config set MEMORY_LIMIT 8g 2>/dev/null
    [ "$("$1" config get SAGENT_NODE_VERSION)" = 24 ]
    "$1" config list | grep -qE "^  SAGENT_NODE_VERSION +24 +config$"
    "$1" config list | grep -qE "^  MEMORY_LIMIT +8g +config$"
    "$1" version | grep -q "^Toolchain: .*node=24 "
    "$1" version | grep -q "^Limits: memory=8g "
    if "$1" config set SAGENT_NODE_VERSION v24 >/dev/null 2>&1; then echo "invalid value accepted" >&2; exit 1; fi
    if "$1" config set NOT_A_SETTING 1 >/dev/null 2>&1; then echo "unknown key accepted" >&2; exit 1; fi
    "$1" config unset MEMORY_LIMIT 2>/dev/null
    if grep -q MEMORY_LIMIT "$cfg/config"; then echo "unset left the key" >&2; exit 1; fi
    "$1" version | grep -q "^Limits: memory=4g "
    [ "$("$1" config path)" = "$cfg/config" ]
    # Environment wins over the file and the command says so.
    SAGENT_TOOLS=js "$1" tools disable tsx 2>&1 | grep -q "takes precedence"
    # Java tools drop out without a JDK; naming one explicitly is an error.
    SAGENT_TOOLS=all SAGENT_JAVA_VERSION=none "$1" version | grep -q "^Tools: typescript tsx bun corepack create-next-app create-vite shadcn$"
    if SAGENT_TOOLS=maven SAGENT_JAVA_VERSION=none "$1" version >/dev/null 2>&1; then echo "java tool without JDK accepted" >&2; exit 1; fi
    bash -n "$cfg/config"
' _ "$SCLAUDE"

# ── T39: status snapshot ─────────────────────────────────────────────
run_test "T39: status snapshot" bash -ec '
    export SAGENT_SKIP_RELEASE_CHECK=1
    out=$("$1" status)
    for key in Wrapper Latest Config Engine Image Toolchain Tools "CA bundle" Nested Limits Credentials Volumes Workspace; do
        echo "$out" | grep -q "^$key:" || { echo "status lacks a $key line" >&2; exit 1; }
    done
    echo "$out" | grep -q "^Engine: .*CLI: $(echo "$out" | sed -n "s/^Engine: .*CLI: \([a-z]*\),.*/\1/p")"
    echo "$out" | grep -q "^Image: .*$SUITE_IMG"
    echo "$out" | grep -q "^Toolchain: *ubuntu="
    echo "$out" | grep -qE "^Workspace: .*(git: |not a git repository)"
    # No engine: status still prints, naming the problem instead of failing.
    SAGENT_CONTAINER_ENGINE=/nonexistent/engine "$1" status | grep -q "^Engine: .*none responding"
' _ "$SCLAUDE"

# ── T40: doctor diagnostics ──────────────────────────────────────────
# A healthy setup with a built image has no FAIL lines and exits 0; the
# checks that spot real problems (missing engine, unmountable workspace,
# rootless docker CLI) report FAIL and exit 1.
run_test "T40: doctor diagnostics" bash -ec '
    export SAGENT_SKIP_RELEASE_CHECK=1
    out=$("$1" doctor) || { echo "$out" >&2; echo "doctor failed on a healthy setup" >&2; exit 1; }
    echo "$out" | grep -qE "^  PASS  engine "
    echo "$out" | grep -qE "^  PASS  workspace "
    echo "$out" | grep -qE "^  PASS  build-tls "
    echo "$out" | grep -qE "^  PASS  image +$SUITE_IMG"
    echo "$out" | grep -qE "^  PASS  cli:claude "
    echo "$out" | grep -qE "^  PASS  cli:gh "
    echo "$out" | grep -qE "^  PASS  network "
    echo "$out" | grep -qE "^  PASS  nested "
    echo "$out" | grep -qE "^  PASS  caches "
    echo "$out" | grep -qE "^Summary: [0-9]+ passed, [0-9]+ warning\(s\), 0 failed$"
    if echo "$out" | grep -q "^  FAIL"; then echo "$out" >&2; exit 1; fi
    # Missing engine: FAIL line, exit 1, and the rest of the report still prints.
    if out=$(SAGENT_CONTAINER_ENGINE=/nonexistent/engine "$1" doctor); then echo "doctor should exit 1 without an engine" >&2; exit 1; fi
    echo "$out" | grep -qE "^  FAIL  engine "
    echo "$out" | grep -qE "^  (PASS|WARN)  auth:claude "
    echo "$out" | grep -q "^Summary: .* 1 failed$"
    # Stub rootless podman behind the docker CLI: workspace check fails.
    tmp=$(mktemp -d /tmp/sagent-t40.XXXXXX)
    trap "rm -rf \"$tmp\"" EXIT
    cat > "$tmp/fake-engine" <<STUB
#!/usr/bin/env bash
case "\$1" in
    info) [ "\${2:-}" = "--format" ] && echo "name=rootless"; exit 0 ;;
    version) printf "Client: Docker Engine\nServer:\n Podman Engine:\n"; exit 0 ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$tmp/fake-engine"
    if out=$(SAGENT_CONTAINER_ENGINE="$tmp/fake-engine" "$1" doctor); then echo "doctor should exit 1 on a rootless docker CLI" >&2; exit 1; fi
    echo "$out" | grep -qE "^  FAIL  workspace .*rootless podman daemon"
' _ "$SCLAUDE"

# ── T43: shell into the sandbox ───────────────────────────────────────
run_test "T43: shell command (fresh and attached)" bash -ec '
    export SAGENT_SKIP_RELEASE_CHECK=1
    WS=$(mktemp -d "$SAGENT_TEST_TMPDIR/sagent-t43.XXXXXX")
    trap "rm -rf \"$WS\"; \"$ENGINE\" rm -f sagent-t43-running >/dev/null 2>&1" EXIT
    echo t43-marker > "$WS/probe.txt"
    # Fresh shell: same workspace mount, no yolo flag, arguments go to bash.
    out=$(cd "$WS" && "$1" shell -c "cat probe.txt; whoami" 2>"$WS/err")
    echo "$out" | grep -q t43-marker
    echo "$out" | grep -q "^agent$"
    grep -q "starting a fresh one" "$WS/err"
    # Attached shell: a sandbox running for this workspace (by label) is joined.
    "$ENGINE" run -d --name sagent-t43-running --label "sagent.workspace=$WS" $SAGENT_TEST_USERNS \
        -v "$(cd "$WS" && pwd -P):$WS:rw" -w "$WS" "$SUITE_IMG" sleep 120 >/dev/null
    cid=$("$ENGINE" ps -q --filter name=sagent-t43-running | head -1)
    out=$(cd "$WS" && "$1" shell -c "hostname" 2>"$WS/err")
    grep -q "Attaching a shell to the sandbox running for $WS" "$WS/err"
    [ "$out" = "${cid:0:12}" ]
' _ "$SCLAUDE"

print_results
