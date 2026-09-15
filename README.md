# sclaude / scodex

Run [Claude Code](https://claude.ai/code) or [OpenAI Codex CLI](https://github.com/openai/codex)
in a Docker or Podman sandbox. The CLI behaves as it does on the host, but it
can only reach the current directory, one folder for files you hand it, and
the host state listed below.

## Requirements

macOS or Linux with bash, and one of: Docker Engine, Docker Desktop, Rancher
Desktop (dockerd engine), colima, or a podman machine. Rootless podman works
through the podman CLI. Rootless Docker is not supported.

Rancher Desktop and colima share only your home directory with their VM, so
run from a directory under it.

`sclaude doctor` checks all of this and names the fix for anything wrong.

## Install

sclaude ships as two self-contained shell scripts and nothing else. Both
go to `~/.local/bin`, without sudo:

```bash
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o sclaude
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/scodex -o scodex
chmod +x sclaude scodex
./sclaude install
```

The sandbox image is not shipped. The first run builds it locally, for your
user and your settings, which takes a few minutes and about 5.5 GB (8 GB
free needed). Behind a TLS-inspecting proxy the build takes the proxy's CA
from your trust store; if the host does not trust it either, see
[corporate proxies](docs/image.md#corporate-proxies). Prebuilt images exist
for CI and dev containers; see [published images](docs/image.md#published-images).

## Update

```bash
sclaude update
```

This updates both wrappers, and it updates Claude Code and Codex in the
image whenever either has a new release, even when sclaude itself has no
new version. The CLIs are the last image layer, so that takes about a
minute. `sclaude update --force-rebuild` rebuilds the whole image.

From a clone, `./sclaude install` links the scripts instead of copying them,
so updating is `git pull && sclaude --build`. `install DIR` or
`SAGENT_INSTALL_DIR` picks another directory; when it is not on PATH,
`install` adds it to your shell startup file, once.

## Use

| Command | What it does |
|---|---|
| `sclaude` | Interactive session. Permission prompts are off (yolo) |
| `sclaude "fix the bug"` | Direct prompt |
| `sclaude --resume` | Resume the last session |
| `sclaude -p "query"` | Print mode, no TTY needed |
| `sclaude --no-yolo` | Keep the permission prompts |
| `sclaude --no-docker` | No docker or podman inside the sandbox |
| `sclaude shell` | Bash in the sandbox for this directory |
| `sclaude mcp add ...` | `claude mcp add ...` inside. Every other `claude` subcommand works the same way |
| `scodex` | The same for Codex |
| `scodex exec "query"` | Non-interactive Codex |

Every native CLI flag passes through. Yolo means
`--dangerously-skip-permissions` for Claude and
`--dangerously-bypass-approvals-and-sandbox` for Codex. The sandbox is what
makes that acceptable.

Commit before you start. Afterwards, review with `git diff` and commit or
`git reset --hard`.

## What the sandbox shares with the host

- The current directory, read-write, at the same path.
- `~/sagent-drop`, read-write. Drop a screenshot on the terminal, or paste
  its path, and either agent can open it. `SAGENT_DROP_DIR` names another
  folder.
- The clipboard, both ways, text and images. Ctrl+V of a screenshot works in
  both agents.
- Session transcripts, so a conversation can be resumed on either side.
- Your git identity and config, your `gh` login, and with SSH remotes your
  `~/.ssh`.
- Your Claude and Codex sign-in. Signing in inside the sandbox works too.

Each of these has a setting that turns it off or narrows it.
[Host state in the sandbox](docs/host-state.md) has the details and
[security](docs/security.md) has the trade-offs.

## What is in the image

Ubuntu 26.04 with Claude Code, Codex, `gh`, git and build tools; Node.js 26,
Python 3.14, Go 1.27, Rust stable and Java 26; and four tool groups you can
drop: `js`, `java`, `infra` (kubectl, Helm, Terraform, Terragrunt) and
`cloud` (AWS, Azure and Google Cloud CLIs). Every version and group is a
setting, and `sclaude tools` shows what is in. [The image](docs/image.md)
lists everything and covers builds, mirrors and disk use.

## Commands

| Command | What it does |
|---|---|
| `sclaude update` | Update both wrappers and the agent CLIs in the image. `--force-rebuild` rebuilds everything |
| `sclaude install [DIR]` | Put both wrappers on PATH |
| `sclaude shell [args]` | Bash in the sandbox. Attaches to the one running for this directory, or starts one |
| `sclaude status` | What a run would use |
| `sclaude doctor` | Diagnostics, with a fix per finding |
| `sclaude tools` | List tools; `enable` and `disable` change the selection |
| `sclaude config` | Show the settings file; `set`, `unset`, `get`, `path` |
| `sclaude volumes` | Disk use per image and volume |
| `sclaude cleanup` | Remove old images |
| `sclaude reset-caches` | Clear the cache volumes, keep credentials and home |
| `sclaude reset` | Delete all persisted state |
| `sclaude --build` | Build the image without running |
| `sclaude dockerfile` | Print the Dockerfile a build would use |
| `sclaude version` | Wrapper, image, toolchain and tool versions |
| `sclaude check-update` | Check for a newer wrapper |

`scodex` has every command too.

## Settings

Settings live in `~/.config/sagent/config`, a bash file that is sourced.
`sclaude config set KEY VALUE` writes it. Environment variables and flags
win over the file.

| Setting | Meaning | Default |
|---|---|---|
| `MEMORY_LIMIT` | Memory limit, a size like `8g` | `4g` |
| `CPU_LIMIT` | CPU limit, a number | `2` |
| `PIDS_LIMIT` | Process limit | `100`, or `512` with container tooling |
| `SAGENT_DOCKER` | `1` for docker and podman inside the sandbox, `0` for none | `1` |
| `SAGENT_CONTAINER_ENGINE` | `docker` or `podman` | docker, then podman |
| `SAGENT_CA_BUNDLE` | PEM file with extra CA certificates for the image | unset |
| `SAGENT_GIT_PROTOCOL` | `ssh` or `https` for GitHub | your gh setting |
| `SAGENT_CLIPBOARD` | `1` to share the host clipboard, `0` not to | `1` |
| `SAGENT_DROP_DIR` | Host folder mounted read-write at the same path inside | `~/sagent-drop` |
| `SAGENT_SESSIONS` | `1` to share transcripts, `0` not to, `all` to share `/rewind` snapshots too | `1` |
| `SAGENT_UBUNTU_VERSION` | Ubuntu release for the image | `26.04` |
| `SAGENT_NODE_VERSION` | Node.js major version | `26` |
| `SAGENT_PYTHON_VERSION` | Python minor version | `3.14` |
| `SAGENT_GO_VERSION` | Go version, or `none` | `1.27` |
| `SAGENT_RUST_VERSION` | `stable`, `beta`, `nightly`, a version, or `none` | `stable` |
| `SAGENT_JAVA_VERSION` | Java major version, or `none` | `26` |
| `SAGENT_TOOLS` | `all`, `none`, group names, or tool names | `all` |
| `SAGENT_APT_MIRROR` | Ubuntu mirror URL for image builds | Ubuntu's archive |
| `SAGENT_AI_ATTRIBUTION` | `1` to let Claude Code sign commits and PRs, `0` not to | `0` |
| `SAGENT_VOLUME_SUFFIX` | Suffix on every volume name, for a separate set of sandbox state | none |

`SAGENT_CONFIG_FILE` points at a different file. Because the file is
sourced, a setting can differ per wrapper:

```bash
[ "$SCRIPT_NAME" = scodex ] && SAGENT_SESSIONS=0
```

## Uninstall

```bash
sclaude reset
docker images sagent-sandbox -q | xargs -r docker rmi
rm ~/.local/bin/sclaude ~/.local/bin/scodex
```

`install DIR` may have put the wrappers elsewhere, and an install from
before 2.16 lives in `/usr/local/bin`. The PATH block `install` added to
your shell startup file is marked `added by sclaude/scodex`.

## More

- [Host state in the sandbox](docs/host-state.md): sessions, clipboard, the
  drop folder, git, gh, ssh, sign-in, MCP servers, attribution.
- [The image](docs/image.md): contents, versions, tool groups, mirrors,
  proxies, published images, dev containers.
- [Storage layout](docs/storage-layout.md): volumes and what lands where.
- [Security](docs/security.md): what the sandbox isolates and what it lets
  through.
- [Testing](docs/e2e-testing.md), [releasing](docs/releasing.md),
  [contributing](CONTRIBUTING.md), [bugs](BUGS.md),
  [changelog](CHANGELOG.md).

## License

MIT

Copyright 2025-2026 [Adrian Mârza](https://www.linkedin.com/in/adrian-m%C3%A2rza-52606512a/).
