# The image

Both wrappers build and use the same sandbox image, for your uid, gid and
settings.

## Contents

Ubuntu 26.04 with Claude Code, Codex, `gh`, git, git-lfs and
build-essential. `SAGENT_UBUNTU_VERSION` picks another release. podman,
its `docker` command shim and docker compose are always installed. Each run
serves podman's Docker API on `/var/run/docker.sock` and `DOCKER_HOST`.
`--no-docker` turns the nested tooling off at run time.

| Toolchain | Default | Setting |
|---|---|---|
| Node.js | 26 | `SAGENT_NODE_VERSION` |
| Python (pip, uv) | 3.14 | `SAGENT_PYTHON_VERSION` |
| Go | 1.27 | `SAGENT_GO_VERSION`, or `none` |
| Rust | stable | `SAGENT_RUST_VERSION`, or `none` |
| Java (Temurin) | 26 | `SAGENT_JAVA_VERSION`, or `none` |

| Group | Tools |
|---|---|
| `js` | TypeScript, tsx, bun, corepack shims for yarn and pnpm, create-next-app, create-vite, shadcn |
| `java` | Maven, Gradle, Quarkus CLI, Spring Boot CLI |
| `infra` | kubectl, Helm, Terraform, Terragrunt |
| `cloud` | AWS CLI v2, Azure CLI, Google Cloud CLI with gsutil and bq |

Utilities: tree, htop, btop, jq, ripgrep, fd, bat, vim, nano, wget, zip,
rsync, ssh, lsof, dig, nc, tmux, sqlite3.

The default image is about 5.5 GB, of which the `cloud` group is about
1.4 GB. The size varies with the architecture and the package versions of
the day. `sclaude tools` lists the selection and the reason for each
exclusion. `sclaude tools disable cloud` drops a group or named tools, and
`sclaude config set SAGENT_GO_VERSION none` drops a toolchain. A change
that alters the generated Dockerfile builds a new image on the next run.
[Toolchain stamps](storage-layout.md#toolchain-stamps) covers the caches
that are cleared then.

## Builds

The wrapper builds the image on your machine, for your uid and gid and your
settings. A build needs about 8 GB free where the engine stores images.
`sclaude doctor` reports what is left, and `sclaude cleanup` removes the
sandbox images other than the current one. On a VM-backed engine the freed
space returns to the host once the VM's disk is trimmed, for example with
`podman machine ssh sudo fstrim -av`.

Layers are ordered by how often they change: base image, OS packages and
toolchains first, then the user and the shims, and the two agent CLIs alone
at the end. A new CLI release rebuilds that last layer, which is what
`sclaude update` does when the earlier layers are cached.
`sclaude update --force-rebuild` pulls the base image and rebuilds every
layer without the cache.

apt and curl retry failed downloads with backoff, and every download lands
in a file before it is unpacked. A build still fails once the retries are
used up.

### Mirrors

Ubuntu packages come from the release's default repositories. To use a
mirror, set `SAGENT_APT_MIRROR`:

```bash
sclaude config set SAGENT_APT_MIRROR http://azure.archive.ubuntu.com/ubuntu/
```

amd64 images take an archive mirror and arm64 images an `ubuntu-ports`
mirror. The build fails when its rewrite of the sources file does not find
the entries it expects. The image keeps the mirror, so `sudo apt install`
inside the sandbox uses it as well. The published images use the default
repositories.

### Corporate proxies

Before each build the wrapper fetches `https://cli.github.com/` from a
plain Ubuntu container. When verification fails, it exports the host's
trust store, retries with that bundle, saves the bundle next to the
settings file, and sets `SAGENT_CA_BUNDLE`. The image then trusts it, and
Node, OpenSSL, requests and pip are pointed at it. If the host does not
trust the proxy's CA either, get it as PEM and name it:

```bash
sclaude config set SAGENT_CA_BUNDLE /path/to/ca.pem
```

Add only certificates you mean the sandbox to trust.
[Extra trust anchors](security.md#extra-trust-anchors) covers the risk.

## Published images

Once a release's image jobs finish, `ghcr.io/e6qu/sagent-sandbox:<version>`
is available for amd64 and arm64, plus `<version>-amd64` and
`<version>-arm64`. There is no `latest` tag. These images use uid and gid
1000 and the default toolchains and tools. They exist for CI and dev
containers. The wrappers build their own images.

The following runs Claude Code directly in the published image, without
the wrapper's mounts, limits, capability drops or host state sync:

```bash
docker run --rm -it -v "$PWD:/workspace" ghcr.io/e6qu/sagent-sandbox:3.1.2 claude
```

## Dev containers

| Config | Purpose |
|---|---|
| [`.devcontainer/`](../.devcontainer/) | Develop sclaude itself |
| [`examples/devcontainer-claude/`](../examples/devcontainer-claude/) | Claude Code directly in a project |
| [`examples/devcontainer-sclaude/`](../examples/devcontainer-sclaude/) | Claude Code through sclaude in a project |

What decides the image hash, and how to add a tool, is in
[Contributing](../CONTRIBUTING.md#what-changes-the-image).
