# sclaude / scodex - Sandboxed Agent CLIs

Run [Claude Code](https://claude.ai/code) or OpenAI Codex CLI in a Docker sandbox.
Same CLI, isolated filesystem.

## Requirements

- Docker or Podman: Docker Engine, Docker Desktop, Rancher Desktop (dockerd
  engine), colima, or a podman machine; rootless podman works through the
  podman CLI (the wrapper maps your user in with `--userns=keep-id`). Rootless
  Docker, and the docker CLI on a rootless podman socket, are refused because
  the docker CLI cannot request that mapping and the workspace would be
  unusable inside the sandbox
- macOS or Linux
- bash (zsh also works)

**Rancher Desktop**: select *Preferences > Container Engine > dockerd (moby)*
and let it put `~/.rd/bin` on your PATH. The containerd engine (`nerdctl`) is
not supported. Rancher Desktop shares only `/Users/$USER` (and
`/tmp/rancher-desktop`) with its VM, and colima likewise shares only your
home directory and `/tmp/colima`, so the wrappers refuse a workspace outside
those paths (it would mount empty); run from under your home directory, or
set `SAGENT_SKIP_SHARE_CHECK=1` if you added the path to the tool's shared
mounts (Rancher Desktop's lima `override.yaml`, colima's `mounts`). Nested
container tooling works in Rancher Desktop's VM; CI runs the full suite
against Rancher Desktop on macOS.

**Something off?** `sclaude doctor` checks the environment end to end (engine,
workspace, config, image, TLS from inside the sandbox, credentials) and names
the fix for anything it flags; `sclaude status` shows what a run would use.

**Corporate networks (TLS-inspecting proxies)**: handled automatically.
Before every image build, the wrapper runs the fetch a build step would run
inside the plain base image. If the network re-signs HTTPS with a CA that
Ubuntu does not know, it takes that CA from the host's own trust store (the
macOS System and login keychains, or the Linux system bundle), verifies it
fixes the fetch, saves it as `~/.config/sagent/ca-bundle.pem`, writes
`SAGENT_CA_BUNDLE` to the config file, and bakes it into the image for curl,
apt, git, Python, pip, Node/npm, the Claude and Codex CLIs, `gh`, and nested
podman. `sclaude status` shows the bundle in effect, `sclaude doctor` names
the CA the proxy presents. The only case that stops with a message is a
proxy CA the host itself does not trust; then obtain it as PEM and point
`SAGENT_CA_BUNDLE` at it:

```bash
sclaude config set SAGENT_CA_BUNDLE /path/to/proxy-ca.pem
sclaude --build
```

The bundle's content is part of the image hash, so changing it triggers a
rebuild.

## Install

```bash
# From latest release
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o sclaude
chmod +x sclaude
sudo mv sclaude /usr/local/bin/sclaude
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/scodex -o scodex
chmod +x scodex
sudo mv scodex /usr/local/bin/scodex

# Or from source
git clone https://github.com/e6qu/sclaude.git
cd sclaude
chmod +x sclaude scodex
sudo ln -s "$(pwd)/sclaude" /usr/local/bin/sclaude
sudo ln -s "$(pwd)/scodex" /usr/local/bin/scodex
```

## Update

```bash
sclaude update                 # Self-update both wrappers and rebuild the shared image with latest CLIs
scodex update                  # Same — self-updates wrappers and rebuilds the shared image
sclaude check-update           # Check (don't install) whether newer wrapper scripts are available

# Update sclaude itself (from source; `update` detects a git checkout and
# skips the wrapper self-download so it never clobbers your working tree)
git pull && sclaude --build

# Or re-download latest release manually
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o /usr/local/bin/sclaude
chmod +x /usr/local/bin/sclaude
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/scodex -o /usr/local/bin/scodex
chmod +x /usr/local/bin/scodex
```

## Usage

```bash
sclaude                      # Interactive mode (yolo by default)
sclaude "fix the bug"        # Direct prompt
sclaude --resume             # Resume last session
sclaude -p "query"           # Print mode (headless/CI, no TTY needed)
sclaude --no-yolo            # Disable default yolo mode
sclaude --no-docker          # Disable docker/podman inside the sandbox
sclaude shell                # Bash in the sandbox: attaches to the one running for this
                             # workspace, else starts a fresh one (args go to bash)

scodex                       # Interactive Codex mode
scodex "fix the bug"         # Direct prompt
scodex exec "query"          # Non-interactive Codex mode
scodex --no-yolo             # Disable Docker-boundary yolo mode
```

Container tooling inside the sandbox is **on by default**: the agent can run
`docker`/`podman` commands via nested rootless podman with a docker CLI shim —
build, run, and pull all work, and nested images persist in the
`sagent-containers` volume. The host engine socket is never mounted and
capabilities stay dropped; the mode does relax the seccomp filter and passes
the fuse/tun devices. Disable it per run with `--no-docker`, or persistently
with `SAGENT_DOCKER=0` (env or config file). See
[Security Architecture](docs/security.md) for the exact tradeoff.

The wrappers autodetect the real engine on both ends: a `docker` command that
is podman's CLI shim, and a real docker CLI talking to a podman server through
the docker-compat socket, are both recognized and get the right build/export
behavior (`sclaude version` shows the detected CLI and server flavors).

Signing in from inside the sandbox works without a browser in it:
`xdg-open`/`$BROWSER` render each URL as a clickable terminal hyperlink, so
Cmd/Ctrl+click opens it in your host browser. A browser can never call back
into the sandbox, so each CLI takes its callback-free path: Claude Code's
sign-in link is rewritten to the manual-code page, and you paste the code it
shows at the "Paste code here" prompt; `scodex login` uses device-code
sign-in (enable it in ChatGPT's security settings if Codex refuses it);
`gh auth login` uses its device code as usual. Credentials you already have
on the host are synced in automatically anyway (Claude keychain or
credentials file, Codex `auth.json`), so signing in on the host first also
works.

The shared image is Ubuntu 26.04 with the Claude Code and Codex CLIs, the
GitHub CLI (`gh`) with `git-lfs`, and full toolchains for Node.js 26, Python 3.14 (with pip
and `uv`), Go 1.27, Rust stable (rustup with rustfmt and clippy), and Java 26
(Eclipse Temurin), plus git, build-essential, rootless podman with a
`docker` shim, and everyday utilities: tree, htop, btop, top, jq, ripgrep,
fd, bat, vim, nano, less, wget, zip/unzip, rsync, ssh, file, lsof, ip, dig,
nc, tmux, sqlite3. Every version is a setting (see [Configuration](#configuration))
and the defaults follow the latest releases; `sclaude version` prints the
toolchain in effect.

On top of the languages, the image carries the everyday tooling at its latest
release as of the build: TypeScript (`tsc`), `tsx`, `bun`, `yarn` and `pnpm`
(through corepack, so a project's `packageManager` field picks the version),
and the `create-next-app`, `create-vite` and `shadcn` scaffolding CLIs; for
Java, Maven, Gradle, the Quarkus CLI and the Spring Boot CLI. Frameworks such
as React, Next.js, htmx, shadcn components, Spring Boot and Quarkus are
project dependencies that this tooling installs into the workspace; their
package caches persist in the home volume. Expect the image to be about
4.3 GB with everything on. Trim it by leaving out toolchains
(`SAGENT_GO_VERSION=none` and friends) or tools:

```bash
sclaude tools                      # what is included, and why not
sclaude tools disable bun gradle   # writes SAGENT_TOOLS to the config file
sclaude tools enable java          # names or the groups all, none, js, java
sclaude config set SAGENT_NODE_VERSION 24   # any setting, validated, written to the config file
sclaude config                     # effective settings and where each comes from
```

A changed selection or version is a new image that builds on the next run.
Upgrades never need anything from you: cache volumes that were filled for the old
toolchain (pip packages are per Python minor, npm globals per Node major, apt
and nested-container state per Ubuntu release) are cleared automatically
with a warning. Go, Rust and Java caches live in the home directory and are
version-independent, so they survive.

Yolo mode is on by default since Docker is the outer sandbox. `sclaude` maps it
to `--dangerously-skip-permissions`; `scodex` maps it to
`--dangerously-bypass-approvals-and-sandbox`. Pass `--no-yolo` to disable.

All native CLI flags are passed through unchanged. Note that `-p` means Claude
print mode for `sclaude`, but Codex profile selection for `scodex`; use native
Codex syntax such as `scodex exec "query"` for non-interactive Codex runs.

Claude OAuth credentials auto-sync from the host (macOS Keychain or
`~/.claude/.credentials.json` on Linux). Codex auth auto-syncs
`${CODEX_HOME:-$HOME/.codex}/auth.json`; API key environment variables are also
passed through. See [Host state inside the sandbox](#host-state-inside-the-sandbox)
for git, gh and the clipboard.

## Host state inside the sandbox

**git and gh work as on the host.** Before every run the wrapper carries
over your global git config (identity, aliases, pull/push/rebase
preferences, the global excludes file) and your `gh` login (the token gh
holds in its keyring or `hosts.yml`, for every host you are logged in to),
so `git push`, `gh pr create` and friends just work. Left out on purpose:
credential helpers, signing settings (no signing keys in the sandbox, so
commits there are unsigned), editor, pager, diff/merge tools and anything
naming a host path or daemon. The synced config is git's XDG-level file;
`git config --global` inside the sandbox writes `~/.gitconfig`, which wins
over it and persists in `sagent-rootfs`. A `gh auth login` made inside the
sandbox stays until the host has a login, which then takes over. `GH_TOKEN`
set on the host is forwarded as is and never written down.

**SSH or HTTPS** for GitHub is `SAGENT_GIT_PROTOCOL`; unset, it follows
the protocol your host `gh` is configured with (`gh config get
git_protocol`, https when never set). With `ssh` the regular files of your
`~/.ssh` (keys, `config` with its `Host` aliases, `known_hosts`) are synced
into the sandbox home, `config` minus the macOS-only `UseKeychain` line and
with `$HOME` paths rewritten to `~`; remotes stay as they are. The sandbox
cannot unlock a passphrase-protected key (no agent, no prompt), so use an
unprotected key for GitHub or switch to https. With `https` no key enters
the sandbox: git serves the gh token through `gh auth git-credential` and
`git@github.com:` remotes are rewritten to HTTPS. Switching removes what
the other mode synced; keys made inside the sandbox are left alone.
`sclaude status` shows the protocol, its source and what will be synced;
`sclaude doctor` flags a missing identity, login or key.

```bash
sclaude config set SAGENT_GIT_PROTOCOL https   # keep SSH keys out of the sandbox
sclaude config set SAGENT_GIT_PROTOCOL ssh     # sync ~/.ssh, keep SSH remotes
```

**Clipboard.** Selecting and pasting text is the terminal's business and
works unchanged; with Claude Code's mouse tracking on, hold Option (iTerm2),
Fn (Terminal.app) or Shift (most others) while dragging to select, as on the
host. Copying *from* the sandbox (Claude Code's `/copy`, `pbcopy`, `xclip`,
`wl-copy` or `xsel` in a script) is turned into an OSC 52 sequence the host
terminal applies to its clipboard: iTerm2 needs *Settings > General >
Selection > Applications in terminal may access clipboard*; kitty, WezTerm,
Ghostty, Alacritty and Windows Terminal support it; Terminal.app does not.
Reading the host clipboard from inside (`pbpaste`, `wl-paste`, `xclip -o`)
is not possible through a terminal and fails with a message; pasted text
arrives as keystrokes (Cmd/Ctrl+V) anyway, only a clipboard image has no way
in: save it into the workspace and give the CLI its path. The terminal's
identity (`TERM_PROGRAM`, `COLORTERM` and friends) is forwarded, so the CLIs
pick the right keyboard protocol (Shift+Enter), print clickable hyperlinks
(Cmd/Ctrl+click opens them on the host) and name the right selection
modifier.

## Commands

| Command | Description |
|---------|-------------|
| `sclaude update` / `scodex update` | Self-update both wrapper scripts to the latest release, then rebuild the shared image with the latest Claude and Codex CLIs (use `SAGENT_SKIP_SELF_UPDATE=1` to skip the wrapper download) |
| `sclaude check-update` / `scodex check-update` | Check whether newer wrapper scripts are available without installing them |
| `sclaude --build` | Build the shared sandbox image without running a CLI (`--force-rebuild` is only accepted with `update`) |
| `sclaude cleanup` | Remove old image versions |
| `sclaude version` | Show version, toolchain, tools and build metadata |
| `sclaude shell [bash args]` | Bash in the sandbox with the same mounts and volumes: attaches to the sandbox running for the current workspace, otherwise starts a fresh one (apt installs last until it exits; npm, pip, cargo, go and home-directory changes persist) |
| `sclaude status` | One-screen snapshot of what a run would use: wrapper and latest release, config and where settings come from, engine and flavors, image state, toolchain and tools, CA bundle, nested mode, limits, credentials found on the host, git identity and gh logins to sync, volumes, workspace |
| `sclaude doctor` | Diagnostics with a fix per finding: engine reachable and usable, workspace mountable, config valid, image built and the CLIs run, TLS from inside the sandbox, nested-container devices, cache stamps, old images, credentials, gh login, git identity, git state, wrapper up to date; exits 1 on any FAIL |
| `sclaude tools` | List the tools available for the image with their status; `tools enable NAME...` / `tools disable NAME...` update `SAGENT_TOOLS` in the config file |
| `sclaude config` | Show effective settings and their source; `config set KEY VALUE`, `config unset KEY`, `config get KEY`, `config path` edit the config file with validation |
| `sclaude volumes` | Disk usage report: image sizes, every volume with its purpose and size, caches total |
| `sclaude reset-caches` | Clear the cache volumes (npm, pip, apt, nested container images); keeps credentials, config and the home directory |
| `sclaude reset` | Delete all persistent data |

## How It Works

```
sclaude [args]  -->  Docker container  -->  claude [args]
scodex [args]   -->  Docker container  -->  codex [args]
                     - Workspace mounted at $(pwd)
                     - Non-root user (your UID/GID)
                     - Shared image with both CLIs
                     - 4GB RAM / 2 CPUs / 100 PIDs (512 with container tooling)
                     - Limited capabilities for sudo apt package installs
                     - Nested docker/podman via rootless podman (no host socket)
                     - Credentials from tool-specific Docker volumes
```

Workspace is the only host directory accessible. Everything else is isolated.

## Persistence

Data survives across runs via Docker volumes:

| Volume | Contents |
|--------|----------|
| `sclaude-config` | Claude credentials, config |
| `scodex-config` | Codex auth and config |
| `sagent-rootfs` | Shared home directory: shell state, synced git config and `gh` login, Go module cache, cargo registry, Maven/Gradle caches |
| `sagent-npm` | Shared npm global packages (cache; cleared on a Node major change) |
| `sagent-pip` | Shared pip user packages and uv-managed Pythons (cache; cleared on a Python minor change) |
| `sagent-apt-cache` | Shared apt package cache (cache; cleared on an Ubuntu change) |
| `sagent-apt-lists` | Shared apt package lists (cache; cleared on an Ubuntu change) |
| `sagent-containers` | Nested container images/state (cache; cleared on an Ubuntu change) |

`sclaude volumes` shows what each one takes up; `sclaude reset-caches`
clears the ones marked cache.

## Configuration

Create `${XDG_CONFIG_HOME:-~/.config}/sagent/config` (plain bash, sourced by
both wrappers; environment variables and flags take precedence):

```bash
MEMORY_LIMIT="8g"          # Default: 4g
CPU_LIMIT="4"              # Default: 2
PIDS_LIMIT="200"           # Default: 100
PIDS_LIMIT_NESTED="1024"   # Default: 512 (used when container tooling is on)
SAGENT_DOCKER=0            # Default: 1 — container tooling inside the sandbox
SAGENT_CONTAINER_ENGINE=podman
SAGENT_CA_BUNDLE="$HOME/.config/sagent/ca-bundle.pem"  # Extra CA certs baked into the image
SAGENT_GIT_PROTOCOL=ssh    # ssh (sync ~/.ssh) or https (gh token, SSH remotes rewritten); default: the host gh's setting

# Toolchain versions (defaults are the latest releases; all part of the image hash)
SAGENT_UBUNTU_VERSION="26.04"   # Ubuntu base image tag
SAGENT_NODE_VERSION="26"        # Node.js major, official tarball (latest patch)
SAGENT_PYTHON_VERSION="3.14"    # CPython minor via uv (latest patch)
SAGENT_GO_VERSION="1.27"        # Go: major.minor (latest patch), exact version, or none
SAGENT_RUST_VERSION="stable"    # Rust: stable, beta, nightly, exact version, or none
SAGENT_JAVA_VERSION="26"        # Java: Temurin JDK major, or none

# Tooling to include (default all): names or groups, comma or space separated.
# js:   typescript tsx bun corepack create-next-app create-vite shadcn
# java: maven gradle quarkus spring (need a JDK; dropped from all/java when SAGENT_JAVA_VERSION=none)
SAGENT_TOOLS="all"              # e.g. "js" or "typescript,bun,maven" or "none"
```

`sclaude config set` and `sclaude tools enable|disable` write these lines for
you; `sclaude config` shows the effective value of every setting and whether
it came from the environment, the file, or the default.

`SAGENT_CONFIG_FILE=/path/to/config` points both wrappers at a different file.

Container engine selection:

```bash
SAGENT_CONTAINER_ENGINE=docker sclaude version
SAGENT_CONTAINER_ENGINE=podman scodex version
```

If `SAGENT_CONTAINER_ENGINE` is unset, the scripts try `docker` first and then
`podman`. Engine health checks are bounded; tune with
`SAGENT_ENGINE_TIMEOUT_SECONDS`.

## Best Practice

```bash
git commit -am "before sclaude"   # Save state
sclaude "fix all bugs"            # Run (yolo by default)
git diff                          # Review
git commit                        # or: git reset --hard
```

## Uninstall

```bash
sclaude cleanup                        # Remove old shared image versions
sclaude reset                          # Remove volumes
docker images sagent-sandbox -q | xargs -r docker rmi # Remove all images
sudo rm /usr/local/bin/sclaude /usr/local/bin/scodex
```

## Dev Containers

Use the dev container for sclaude development, or copy an example into your own project:

| Config | Purpose |
|--------|---------|
| [`.devcontainer/`](.devcontainer/) | Develop sclaude itself (Docker-in-Docker, shellcheck, zsh) |
| [`examples/devcontainer-claude/`](examples/devcontainer-claude/) | Use Claude Code directly in any project |
| [`examples/devcontainer-sclaude/`](examples/devcontainer-sclaude/) | Use Claude Code via sclaude (sandboxed) in any project |

```bash
# Test all devcontainers locally
npm install -g @devcontainers/cli
bash test_devcontainers.sh
```

## Docs

- [Security Architecture](docs/security.md) - Threat model, attack scenarios, hardening
- [Storage Layout](docs/storage-layout.md) - Volume architecture and credential sync
- [E2E Testing](docs/e2e-testing.md) - Test matrix and cross-platform CI topologies
- [Bug Tracker](BUGS.md) - Known issues and fix history
- [Changelog](CHANGELOG.md) - Release history
- [Contributing](CONTRIBUTING.md)

## License

MIT
