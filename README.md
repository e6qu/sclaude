# sclaude / scodex - Sandboxed Agent CLIs

Run [Claude Code](https://claude.ai/code) or OpenAI Codex CLI in a Docker sandbox.
Same CLI, isolated filesystem.

## Requirements

- Docker or Podman: Docker Engine, Docker Desktop, Rancher Desktop (dockerd
  engine), colima, or a podman machine
- macOS or Linux
- bash (zsh also works)

**Rancher Desktop**: select *Preferences > Container Engine > dockerd (moby)*
and let it put `~/.rd/bin` on your PATH. The containerd engine (`nerdctl`) is
not supported. Rancher Desktop shares only `/Users/$USER` (and
`/tmp/rancher-desktop`) with its VM, so run the wrappers from a workspace
under your home directory or the bind mount comes up empty. Nested container
tooling needs `/dev/fuse` and `/dev/net/tun` in the engine VM; if `docker run`
rejects either device, run with `--no-docker` (or `SAGENT_DOCKER=0`).

**Corporate networks (TLS-inspecting proxies)**: if the first build fails with
`curl: (60) SSL certificate problem: unable to get local issuer certificate`,
your proxy re-signs HTTPS traffic with a CA your machine trusts but a fresh
Ubuntu image does not. Docker Desktop and Rancher Desktop apply the host's
CAs to image pulls only, never to build steps or running containers. Export
that CA to a PEM file and point `SAGENT_CA_BUNDLE` at it; the wrappers bake
it into the image for curl, apt, git, Python, pip, Node/npm, the Claude and
Codex CLIs, `gh`, and nested podman:

```bash
mkdir -p ~/.config/sagent
# macOS: every certificate in the System keychain (where MDM/proxy CAs land)
security find-certificate -a -p /Library/Keychains/System.keychain > ~/.config/sagent/ca-bundle.pem
# Linux: copy the proxy CA from /usr/local/share/ca-certificates or /etc/pki/ca-trust/source/anchors
echo 'SAGENT_CA_BUNDLE="$HOME/.config/sagent/ca-bundle.pem"' >> ~/.config/sagent/config
sclaude --build
```

The bundle's content is part of the image hash, so changing it triggers a
rebuild; `sclaude version` shows which bundle is in effect.

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

Browser login flows work from inside the sandbox: `xdg-open`/`$BROWSER` render
each URL as a clickable terminal hyperlink, so Cmd/Ctrl+click in the TUI opens
it in your host browser (claude and codex logins, `gh auth login`).

The shared image is Ubuntu 24.04 with the Claude Code and Codex CLIs, the
GitHub CLI (`gh`), Node.js 24, Python 3 with pip, git, build-essential, and
rootless podman with a `docker` shim. `gh` authenticates either with
`gh auth login` inside the sandbox (persisted in the `sagent-rootfs` volume)
or with a `GH_TOKEN` set on the host, which is passed through.

Yolo mode is on by default since Docker is the outer sandbox. `sclaude` maps it
to `--dangerously-skip-permissions`; `scodex` maps it to
`--dangerously-bypass-approvals-and-sandbox`. Pass `--no-yolo` to disable.

All native CLI flags are passed through unchanged. Note that `-p` means Claude
print mode for `sclaude`, but Codex profile selection for `scodex`; use native
Codex syntax such as `scodex exec "query"` for non-interactive Codex runs.

Claude OAuth credentials auto-sync from the host (macOS Keychain or
`~/.claude/.credentials.json` on Linux). Codex auth auto-syncs
`${CODEX_HOME:-$HOME/.codex}/auth.json`; API key environment variables are also
passed through.

## Commands

| Command | Description |
|---------|-------------|
| `sclaude update` / `scodex update` | Self-update both wrapper scripts to the latest release, then rebuild the shared image with the latest Claude and Codex CLIs (use `SAGENT_SKIP_SELF_UPDATE=1` to skip the wrapper download) |
| `sclaude check-update` / `scodex check-update` | Check whether newer wrapper scripts are available without installing them |
| `sclaude cleanup` | Remove old image versions |
| `sclaude version` | Show version and build metadata |
| `sclaude volumes` | Show Docker volume info |
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
| `sagent-rootfs` | Shared home directory, preferences |
| `sagent-npm` | Shared npm global packages |
| `sagent-pip` | Shared pip user packages |
| `sagent-apt-cache` | Shared apt package cache |
| `sagent-apt-lists` | Shared apt package lists |
| `sagent-containers` | Nested container images/state (`--docker` mode) |

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
```

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
