# The image

What the sandbox image contains, how it is built, and what changes it.

## Contents

Ubuntu 26.04 with Claude Code, Codex, `gh`, git, git-lfs and
build-essential.

| Toolchain | Default | Setting |
|---|---|---|
| Node.js | 26 | `SAGENT_NODE_VERSION` |
| Python (pip, uv) | 3.14 | `SAGENT_PYTHON_VERSION` |
| Go | 1.27 | `SAGENT_GO_VERSION`, or `none` |
| Rust | stable | `SAGENT_RUST_VERSION`, or `none` |
| Java (Temurin) | 26 | `SAGENT_JAVA_VERSION`, or `none` |

| Group | Tools |
|---|---|
| `js` | TypeScript, tsx, bun, yarn and pnpm (corepack), create-next-app, create-vite, shadcn |
| `java` | Maven, Gradle, Quarkus CLI, Spring Boot CLI |
| `infra` | kubectl, Helm, Terraform, Terragrunt |
| `cloud` | AWS CLI v2, Azure CLI, Google Cloud CLI with gsutil and bq |

Utilities: tree, htop, btop, jq, ripgrep, fd, bat, vim, nano, wget, zip,
rsync, ssh, lsof, dig, nc, tmux, sqlite3.

Everything together is about 5.5 GB; the `cloud` group is 1.4 GB of that.
`sclaude tools` lists what is in and why not. `sclaude tools disable cloud`
drops a group (or named tools), and `sclaude config set SAGENT_GO_VERSION
none` drops a toolchain. Any change builds a new image on the next run, and
caches that belong to an old toolchain are cleared then.

## Builds

The image is built locally, for your uid and gid and your settings. A build
needs about 8 GB free where the engine stores images. `sclaude doctor`
reports what is left and `sclaude cleanup` removes old images. On a
VM-backed engine the freed space returns to the host after the VM is
trimmed (`podman machine ssh sudo fstrim -av`) or restarted.

Layers are ordered by how often they change: base image, OS packages and
toolchains first, then the user and the shims, and the two agent CLIs alone
at the end. A new CLI release therefore rebuilds one layer, which is what
`sclaude update` does. The build metadata is an image label, so a rebuild
with nothing to do is a no-op.

apt and curl retry with backoff, and every download lands in a file before
it is unpacked, so one dropped connection does not fail the build.

### Mirrors

Packages come from Ubuntu's archive. If you sit next to a mirror, name it:

```bash
sclaude config set SAGENT_APT_MIRROR http://azure.archive.ubuntu.com/ubuntu/
```

The mirror has to match what you are building: amd64 images want an archive
mirror, arm64 images a `ubuntu-ports` one. A sources layout the rewrite does
not recognise fails the build. The image keeps the sources, so `sudo apt
install` inside the sandbox uses the mirror too. The published images are
built without one.

### Corporate proxies

Before the first build the wrapper checks whether HTTPS from a container is
intercepted. If it is, it takes the proxy's CA from the host trust store and
bakes it into the image, and points Node, OpenSSL, requests and pip at it.
If the host does not trust that CA either, get it as PEM and name it:

```bash
sclaude config set SAGENT_CA_BUNDLE /path/to/ca.pem
```

Whoever controls that CA can read the sandbox's HTTPS traffic. That is
already true on the host on such a network; the wrapper extends the same
trust to the sandbox, for the file you name.

## Published images

Each release publishes `ghcr.io/e6qu/sagent-sandbox:<version>` (multi-arch),
plus `<version>-amd64` and `<version>-arm64`. There is no `latest` tag. They
are built for uid and gid 1000 with the default toolchains and tools, for
use in CI or dev containers; the wrappers build locally for your own uid and
settings.

```bash
docker run --rm -it -v "$PWD:/workspace" ghcr.io/e6qu/sagent-sandbox:3.1.2 claude
```

## Dev containers

| Config | Purpose |
|---|---|
| [`.devcontainer/`](../.devcontainer/) | Develop sclaude itself |
| [`examples/devcontainer-claude/`](../examples/devcontainer-claude/) | Claude Code directly in a project |
| [`examples/devcontainer-sclaude/`](../examples/devcontainer-sclaude/) | Claude Code through sclaude in a project |

## For contributors: what changes the image

The image hash covers the generated Dockerfile (toolchain versions and the
tool selection included), the uid and gid build arguments, and the CA
bundle. Any change to the Dockerfile text in the wrappers, to a version
default, or to the tool registry gives a new hash, and every user rebuilds
on their next run. Changes elsewhere in the wrappers (flags, commands,
messages) keep the hash.

Version defaults are the `*_VERSION` constants near the top of the
wrappers. Optional tools are the `SAGENT_TOOL_REGISTRY` table (name, group,
description) plus one install fragment per tool, in `get_dockerfile_content`
for the npm and Java tools and in `emit_extra_tools` for the infra and cloud
ones, plus one presence check per tool in test T19. Volume stamps take their
values from the settings.
