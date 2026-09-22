# sclaude / scodex

Run [Claude Code](https://claude.ai/code) or [OpenAI Codex CLI](https://github.com/openai/codex)
in a Docker or Podman sandbox. The CLI runs as it does on the host. It can
reach the current directory, one folder for files you hand it, the host
state listed below, and the network.

## Requirements

macOS or Linux with bash, and a container engine: Docker Engine, Docker
Desktop, Rancher Desktop with the dockerd engine, colima, or a podman
machine. Rootless podman works through the podman CLI. Rootless Docker is
not supported.

Rancher Desktop and colima share only your home directory with their VM.
Run from a directory under it, or set `SAGENT_SKIP_SHARE_CHECK=1` for a
path you shared yourself.

`sclaude doctor` checks these and names the fix for what it finds.

## Install

sclaude ships as two self-contained shell scripts. `install` puts both in
`~/.local/bin` without sudo, and adds that directory to your shell startup
file if it is missing from PATH. Open a new shell afterwards.

```bash
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o sclaude
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/scodex -o scodex
chmod +x sclaude scodex
./sclaude install
```

From a clone, `./sclaude install` links the scripts, so `git pull` updates
them. `install DIR` or `SAGENT_INSTALL_DIR` picks another directory.

No image is downloaded. The first run builds the sandbox image on your
machine, for your user and your settings. That takes a few minutes and
about 5.5 GB of disk, with 8 GB free needed during the build. Behind a
TLS-inspecting proxy the build takes the proxy's CA from your trust store.
If the host does not trust it either, see
[corporate proxies](docs/image.md#corporate-proxies). Prebuilt images for
CI and dev containers are listed under
[published images](docs/image.md#published-images).

## Update

```bash
sclaude update
```

This updates both wrappers. It also updates Claude Code and Codex in the
image whenever either has a new release, even when sclaude itself has none.
The two CLIs are the last image layer, so that takes about a minute.

`sclaude update --force-rebuild` rebuilds the whole image and updates
everything else in it to the newest release its source offers: the Ubuntu
base image and packages, `gh`, git, Node.js, Python, Go, Rust and Java
within the configured versions, the tool groups (TypeScript, bun, yarn,
pnpm; Maven, Gradle, Quarkus, Spring Boot; kubectl, Helm, Terraform,
Terragrunt; AWS, Azure and Google Cloud CLIs), and the two agent CLIs. That
takes several minutes. A new sclaude version that changes the image rebuilds
it on the next run.

From a clone, `update` leaves the scripts to `git pull` and updates the
image: `git pull && sclaude update`.

## Use

| Command | What it does |
|---|---|
| `sclaude` | Interactive session. Permission prompts are off (yolo) |
| `sclaude "fix the bug"` | Direct prompt |
| `sclaude --continue` | Continue the last session in this directory. `--resume` picks one |
| `sclaude -p "query"` | Print mode, no TTY needed |
| `sclaude --no-yolo` | Keep the permission prompts |
| `sclaude --no-docker` | Turn off nested containers for this run |
| `sclaude shell` | Bash in the sandbox for this directory |
| `sclaude mcp add ...` | `claude mcp add ...` inside. Other `claude` subcommands pass through the same way, apart from the wrapper's own commands below |
| `scodex` | The same for Codex |
| `scodex exec "query"` | Non-interactive Codex |

Every native CLI flag passes through. Yolo means
`--dangerously-skip-permissions` for Claude and
`--dangerously-bypass-approvals-and-sandbox` for Codex. The sandbox limits
what that can reach. [Security](docs/security.md) says how far.

Commit before you start. Afterwards, review with `git diff`, then commit or
`git reset --hard`, which discards every uncommitted change.

## What the sandbox shares with the host

- The current directory, read-write, at the same path.
- `~/sagent-drop`, read-write. Drop a screenshot on the terminal, or paste
  its path, and either agent can open it. `SAGENT_DROP_DIR` names another
  folder.
- Any other folders you list in `SAGENT_EXTRA_MOUNTS`, read-only unless
  marked `:rw`. None by default.
- The clipboard, both ways, text and images. Ctrl+V of a screenshot works in
  both agents.
- Session transcripts. A conversation can be resumed on either side.
- Your git identity and config, your `gh` login, and with SSH remotes your
  `~/.ssh`.
- Your sign-in for the agent you run. Signing in inside the sandbox works
  too.

Most of these have a setting that turns them off or narrows them.
[Host state in the sandbox](docs/host-state.md) has the details and
[security](docs/security.md) has the trade-offs.

## What is in the image

Ubuntu 26.04 with Claude Code, Codex, `gh`, git and build tools. Node.js 26,
Python 3.14, Go 1.27, Rust stable and Java 26. Four tool groups you can
drop: `js`, `java`, `infra` (kubectl, Helm, Terraform, Terragrunt) and
`cloud` (AWS, Azure and Google Cloud CLIs). Every version and group is a
setting. `sclaude tools` shows what is in. [The image](docs/image.md) lists
everything and covers builds, mirrors and disk use.

## Commands

| Command | What it does |
|---|---|
| `sclaude update` | Update both wrappers and the agent CLIs in the image. `--force-rebuild` rebuilds everything |
| `sclaude install [DIR]` | Put both wrappers on PATH |
| `sclaude shell [args]` | Bash in the sandbox. Attaches to the one running for this directory, or starts one |
| `sclaude status` | What a run would use |
| `sclaude doctor` | Diagnostics, with a fix per finding |
| `sclaude tools` | List tools. `enable` and `disable` change the selection |
| `sclaude config` | Show the settings file. `set`, `unset`, `get`, `path` |
| `sclaude volumes` | Disk use per image and volume |
| `sclaude cleanup` | Remove the sandbox images other than the current one |
| `sclaude reset-caches` | Clear the npm, pip, apt and nested-container volumes. Credentials and home stay |
| `sclaude reset` | Delete every sandbox volume. The workspace, the drop folder, host transcripts and the image stay |
| `sclaude --build` | Build the image without running |
| `sclaude dockerfile` | Print the Dockerfile a build would use |
| `sclaude version` | Wrapper, image, toolchain and tool versions |
| `sclaude check-update` | Check for a newer wrapper |

Both wrappers have these commands.

## Settings

Settings live in `~/.config/sagent/config`, a bash file that is sourced.
`sclaude config set KEY VALUE` writes it. For the `SAGENT_` settings, an
environment variable wins over the file. The resource limits are read from
the file only.

| Setting | Meaning | Default |
|---|---|---|
| `MEMORY_LIMIT` | Memory limit, a size like `16g` | `8g` |
| `CPU_LIMIT` | CPU limit, a number | `4` |
| `PIDS_LIMIT` | Process limit without nested containers | `100` |
| `PIDS_LIMIT_NESTED` | Process limit with nested containers | `512` |
| `SAGENT_DOCKER` | `1` for docker and podman inside the sandbox, `0` for none | `1` |
| `SAGENT_CONTAINER_ENGINE` | `docker` or `podman` | docker, then podman |
| `SAGENT_CA_BUNDLE` | PEM file with extra CA certificates for the image | unset |
| `SAGENT_GIT_PROTOCOL` | `ssh` or `https` for GitHub | your gh setting, else `https` |
| `SAGENT_CLIPBOARD` | `1` to share the host clipboard, `0` to keep it out | `1` |
| `SAGENT_DROP_DIR` | Host folder mounted read-write at the same path inside | `~/sagent-drop` |
| `SAGENT_EXTRA_MOUNTS` | More host folders, comma-separated, each at the same path inside, read-only unless it ends in `:rw` | none |
| `SAGENT_SESSIONS` | `1` to share transcripts, `0` to keep them out, `all` to share `/rewind` snapshots too | `1` |
| `SAGENT_UBUNTU_VERSION` | Ubuntu release for the image | `26.04` |
| `SAGENT_NODE_VERSION` | Node.js major version | `26` |
| `SAGENT_PYTHON_VERSION` | Python minor version | `3.14` |
| `SAGENT_GO_VERSION` | Go version, or `none` | `1.27` |
| `SAGENT_RUST_VERSION` | `stable`, `beta`, `nightly`, a version, or `none` | `stable` |
| `SAGENT_JAVA_VERSION` | Java major version, or `none` | `26` |
| `SAGENT_TOOLS` | `all`, `none`, group names, or tool names | `all` |
| `SAGENT_APT_MIRROR` | Ubuntu mirror URL for image builds | Ubuntu's archive |
| `SAGENT_AI_ATTRIBUTION` | `0` keeps Claude Code's commit and PR attribution off. `1` leaves it to Claude's own settings | `0` |
| `SAGENT_VOLUME_SUFFIX` | Suffix on every volume name, for a second set of volumes | none |

`SAGENT_CONFIG_FILE` points at a different file. The file is sourced, so a
setting can differ per wrapper:

```bash
[ "$SCRIPT_NAME" = scodex ] && SAGENT_SESSIONS=0
```

## Uninstall

```bash
sclaude reset
docker images sagent-sandbox -q | xargs -r docker rmi
rm ~/.local/bin/sclaude ~/.local/bin/scodex
```

With podman, replace `docker` with `podman`. `install DIR` may have put the
wrappers elsewhere. An install from before 2.16 lives in `/usr/local/bin`.
The PATH block `install` added to your shell startup file is marked
`added by sclaude/scodex`. The settings file and `~/sagent-drop` stay.

## Documentation

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

[MIT](LICENSE)

Copyright 2025-2026 [Adrian Mârza](https://www.linkedin.com/in/adrian-m%C3%A2rza-52606512a/).
