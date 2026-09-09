# sclaude / scodex

Run [Claude Code](https://claude.ai/code) or OpenAI Codex CLI in a Docker
sandbox. Same CLI, isolated filesystem. Only the current directory is shared.

## Requirements

- macOS or Linux, bash (zsh works too)
- Docker or Podman: Docker Engine, Docker Desktop, Rancher Desktop (dockerd
  engine, not containerd), colima, or a podman machine. Rootless podman works
  with the podman CLI. Rootless Docker is not supported.

Rancher Desktop and colima share only your home directory with their VM, so
run from under your home directory (or set `SAGENT_SKIP_SHARE_CHECK=1` if you
added more shares).

TLS-inspecting proxies are handled automatically: the wrapper takes the
proxy's CA from the host trust store and bakes it into the image. If the host
does not trust the CA either, get it as PEM and run
`sclaude config set SAGENT_CA_BUNDLE /path/to/ca.pem`.

Something off? `sclaude doctor` checks everything and names the fix.
`sclaude status` shows what a run would use.

## Install

```bash
# Release
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o sclaude
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/scodex -o scodex
chmod +x sclaude scodex
sudo mv sclaude scodex /usr/local/bin/

# Source
git clone https://github.com/e6qu/sclaude.git && cd sclaude
sudo ln -s "$(pwd)/sclaude" "$(pwd)/scodex" /usr/local/bin/
```

Update with `sclaude update`: it updates both wrappers and, when the Claude
or Codex CLI has a new release, reinstalls them in the image. That is the
last layer, so it takes a minute rather than a full rebuild;
`sclaude update --force-rebuild` rebuilds everything from scratch (new base
image, OS packages, toolchains). From source: `git pull && sclaude --build`.

## Usage

```bash
sclaude                      # Interactive (yolo by default)
sclaude "fix the bug"        # Direct prompt
sclaude --resume             # Resume last session
sclaude -p "query"           # Print mode, no TTY needed
sclaude --no-yolo            # Ask for permissions
sclaude --no-docker          # No docker/podman inside the sandbox
sclaude shell                # Bash in the running sandbox for this directory

scodex                       # Same for Codex
scodex exec "query"          # Non-interactive Codex
```

All native CLI flags pass through. Yolo maps to
`--dangerously-skip-permissions` (Claude) and
`--dangerously-bypass-approvals-and-sandbox` (Codex); Docker is the sandbox.

**Shell in a running session**: from a second terminal, in the same
directory, `sclaude shell`. Inside the TUI, `!command` runs one command.

**Sign-in** works without a browser in the sandbox: URLs print as clickable
links, Claude Code uses its paste-a-code flow, Codex uses device-code
sign-in. Host credentials (Claude keychain or credentials file, Codex
`auth.json`) are synced in anyway.

**Container tooling** inside the sandbox is on by default: `docker`/`podman`
run through nested rootless podman, no host socket. Turn off with
`--no-docker` or `SAGENT_DOCKER=0`. See [security](docs/security.md).

## What's in the image

Ubuntu 26.04 with Claude Code, Codex, `gh`, git, git-lfs, build-essential
and toolchains: Node.js 26, Python 3.14 (pip, uv), Go 1.27, Rust stable, Java
26 (Temurin). Tooling: TypeScript, tsx, bun, yarn and pnpm (corepack),
create-next-app, create-vite, shadcn, Maven, Gradle, Quarkus CLI, Spring
Boot CLI. Utilities: tree, htop, btop, jq, ripgrep, fd, bat, vim, nano, wget,
zip, rsync, ssh, lsof, dig, nc, tmux, sqlite3.

About 4.3 GB. Every version and tool is a setting:

```bash
sclaude tools                          # what is in and why not
sclaude tools disable bun gradle
sclaude config set SAGENT_GO_VERSION none
```

Changing any of them builds a new image on the next run. Caches that belong
to an old toolchain are cleared automatically.

Layers are ordered by how often they change: base image, OS packages and
toolchains first, then the user and shims, and the two agent CLIs alone at
the end. A CLI release therefore rebuilds one layer; the build metadata is
an image label rather than a file, so a rebuild with nothing to do is a
no-op instead of a full image export.

A build needs about 8 GB free where the engine stores images. `sclaude
doctor` reports what is left and `sclaude cleanup` reclaims it; on a
VM-backed engine the freed space returns to the host only after the VM is
trimmed (`podman machine ssh sudo fstrim -av`) or restarted.

## Host state inside the sandbox

**git and gh.** Your global git config (identity, aliases, preferences,
excludes file) and your `gh` login are synced in on every run. Not synced:
credential helpers, signing (commits in the sandbox are unsigned), editor,
pager, diff/merge tools, host paths. `git config --global` inside the sandbox
writes `~/.gitconfig`, which wins and persists.

**SSH or HTTPS** for GitHub follows your host `gh` setting, or
`SAGENT_GIT_PROTOCOL`:

- `ssh`: `~/.ssh` (keys, config, known_hosts) is synced in. Passphrase-
  protected keys cannot be unlocked there.
- `https`: no keys go in; git uses the gh token and `git@github.com:`
  remotes are rewritten to HTTPS.

**Clipboard** is the host's, both ways, text and images. `pbcopy`, `pbpaste`,
`xclip`, `xsel`, `wl-copy` and `wl-paste` in the sandbox talk to the host
clipboard through the wrapper. Selecting in Claude Code's TUI copies to your
clipboard; Ctrl+V pastes a host screenshot. Works on macOS and Linux
desktops; a headless Linux host has no clipboard to share. The sandbox can
read your clipboard at any time; `SAGENT_CLIPBOARD=0` turns this off.

Terminal identity (`TERM_PROGRAM` etc.) is forwarded, so Shift+Enter,
clickable links and the selection hint work as on the host. With Claude
Code's mouse tracking on, hold Option (iTerm2) or Shift for native terminal
selection.

## Commands

| Command | Description |
|---------|-------------|
| `sclaude update` | Update both wrappers; reinstall the agent CLIs in the image when they have a new release (`--force-rebuild` rebuilds everything) |
| `sclaude check-update` | Check for a newer wrapper |
| `sclaude --build` | Build the image without running |
| `sclaude cleanup` | Remove old image versions |
| `sclaude dockerfile` | Print the Dockerfile a build would use |
| `sclaude version` | Version, toolchain, tools, build metadata |
| `sclaude shell [args]` | Bash in the sandbox (attach to the running one, or start one) |
| `sclaude status` | What a run would use |
| `sclaude doctor` | Diagnostics with a fix per finding |
| `sclaude tools` | List, `enable`, `disable` tools |
| `sclaude config` | Show, `set`, `unset`, `get` settings; `path` |
| `sclaude volumes` | Disk usage per image and volume |
| `sclaude reset-caches` | Clear cache volumes, keep credentials and home |
| `sclaude reset` | Delete all persistent data |

Every `sclaude` command exists for `scodex` too.

## Persistence

| Volume | Contents |
|--------|----------|
| `sclaude-config` | Claude credentials, config, sessions |
| `scodex-config` | Codex auth and config |
| `sagent-rootfs` | Home directory: shell state, git/gh/ssh sync, Go, cargo, Maven, Gradle caches |
| `sagent-npm` | npm globals (cache) |
| `sagent-pip` | pip packages, uv Pythons (cache) |
| `sagent-apt-cache`, `sagent-apt-lists` | apt (cache) |
| `sagent-containers` | Nested container images (cache) |

## Configuration

`~/.config/sagent/config`, plain bash. Environment variables and flags win.
`sclaude config set KEY VALUE` writes it for you.

```bash
MEMORY_LIMIT="8g"               # default 4g
CPU_LIMIT="4"                   # default 2
PIDS_LIMIT="200"                # default 100 (512 with container tooling)
SAGENT_DOCKER=0                 # container tooling inside the sandbox, default 1
SAGENT_CONTAINER_ENGINE=podman  # default: docker, then podman
SAGENT_CA_BUNDLE=/path/ca.pem   # extra CA certificates
SAGENT_GIT_PROTOCOL=ssh         # ssh or https, default: your gh setting
SAGENT_CLIPBOARD=0              # host clipboard in the sandbox, default 1

SAGENT_UBUNTU_VERSION="26.04"
SAGENT_NODE_VERSION="26"
SAGENT_PYTHON_VERSION="3.14"
SAGENT_GO_VERSION="1.27"        # or none
SAGENT_RUST_VERSION="stable"    # or none
SAGENT_JAVA_VERSION="26"        # or none
SAGENT_TOOLS="all"              # all, none, js, java, or names
```

`SAGENT_CONFIG_FILE` points at a different file.

## Published images

Each release publishes `ghcr.io/e6qu/sagent-sandbox:<version>` (multi-arch),
`<version>-amd64` and `<version>-arm64`. No `latest`. Built for uid/gid 1000
with the default toolchain, for direct use in CI or dev containers; the
wrappers build locally for your own uid and settings.

```bash
docker run --rm -it -v "$PWD:/workspace" ghcr.io/e6qu/sagent-sandbox:2.14.0 claude
```

## Best practice

```bash
git commit -am "before sclaude"
sclaude "fix all bugs"
git diff                          # review, then commit or reset --hard
```

## Uninstall

```bash
sclaude reset
docker images sagent-sandbox -q | xargs -r docker rmi
sudo rm /usr/local/bin/sclaude /usr/local/bin/scodex
```

## Dev containers

| Config | Purpose |
|--------|---------|
| [`.devcontainer/`](.devcontainer/) | Develop sclaude itself |
| [`examples/devcontainer-claude/`](examples/devcontainer-claude/) | Claude Code directly in a project |
| [`examples/devcontainer-sclaude/`](examples/devcontainer-sclaude/) | Claude Code via sclaude in a project |

## Docs

- [Security](docs/security.md)
- [Storage layout](docs/storage-layout.md)
- [E2E testing](docs/e2e-testing.md)
- [Bugs](BUGS.md), [Changelog](CHANGELOG.md), [Contributing](CONTRIBUTING.md)

## License

MIT
