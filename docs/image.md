# The image

Both wrappers build and use the same sandbox image, for your uid, gid and
settings.

## Contents

Ubuntu with Claude Code, Codex, `gh`, git, git-lfs and
build-essential. `SAGENT_UBUNTU_VERSION` picks another release. Podman,
the Docker CLI, Compose, Buildx and BuildKit are always installed. With
nested containers enabled, each run serves Podman's Docker API at the
Unix socket selected by `DOCKER_HOST` and `/var/run/docker.sock`.
`--no-docker` turns the nested tooling off at run time.

Tini is installed from Ubuntu's packages and is the image entrypoint. It
reaps orphaned children, forwards signals to the main tool and preserves
its exit status, including for direct `docker run` or `podman run` launches.
The default command is Bash. See [resource limits](security.md#resource-limits)
for process budgets and concurrent-session behavior.

| Toolchain | Setting |
|---|---|
| Node.js | `SAGENT_NODE_VERSION` |
| Python (pip, uv) | `SAGENT_PYTHON_VERSION` |
| Go | `SAGENT_GO_VERSION`, or `none` |
| Rust | `SAGENT_RUST_VERSION`, or `none` |
| Java (Temurin) | `SAGENT_JAVA_VERSION`, or `none` |

[Settings](../README.md#settings) lists the current defaults.

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

## Nested containers

The Docker CLI, Compose and Docker SDKs use Podman's Docker-compatible API,
served inside the sandbox with
`podman system service --time=0`. `DOCKER_HOST` points to
`unix:///run/podman/podman.sock`; `/var/run/docker.sock` links there too.
This is the sandbox's socket on both macOS and Linux, never the host's.
Startup and the `docker` launcher wait for an API response, including when a
dead service leaves a socket file behind. A supervisor restarts the service
if it exits.

Nested storage is reserved per project and sandbox. Different projects use
different stores. Concurrent sandboxes in the same project reserve separate
numbered slots, so their daemons, containers, images and Compose volumes do
not collide. The lowest available slot is reused on the next start, keeping
its images, build cache and named-volume data. Concurrent slots have their
own data; data written in one slot is not copied to another. Bind-mounted
project data still follows the project's host files.

If Compose cannot connect, run these inside the sandbox:

```bash
sagent-docker-api
curl --fail --noproxy '*' --max-time 5 --unix-socket /var/run/docker.sock http://localhost/_ping
tail -n 50 /tmp/sagent-docker-api.log
```

The ping should return `OK`. After updating the wrapper or image, start
a new sandbox to use it. Compose uses Podman's Docker compatibility API;
Docker-specific behavior depends on that API's support.

## Nested builds and browser tests

`docker build`, `docker buildx build` and `docker compose build` use a
rootless BuildKit service in the sandbox. The `sagent` Buildx builder uses
the remote driver over `/run/buildkit/buildkitd.sock` and loads built images
into the nested Podman store by default. BuildKit cache, secret and SSH mounts, multi-stage builds, multi-platform
OCI exports and non-root image users are supported. Build cache
persists in the containers volume. `docker buildx prune` clears it.

Compose health checks are scheduled inside the sandbox, which has no
systemd user manager. The scheduler calls `podman healthcheck run`; Podman
handles each check's timeout, start period, retries and health status.
This supports `depends_on: condition: service_healthy` and `compose up --wait`.

BuildKit starts on the first `docker build` (also `docker image build`),
`docker buildx`, `docker builder`
or `docker compose` command and restarts if it exits. Shell sessions and
`docker run`, `docker ps` and `docker info` do not start BuildKit. The Podman
API stays available from session startup for SDKs and Testcontainers. BuildKit
logs to `/tmp/sagent-buildkit.log`. Readiness probes allow five seconds per RPC,
with a 120-second startup deadline. Startup failures print the last 40
log lines. For crashes, retain the full log before restarting the sandbox;
see [known issues](../BUGS.md#buildkit-sigill-on-intel-macos-vms).
The image sets `DOCKER_BUILDKIT=1` and `BUILDX_BUILDER=sagent`.
`BUILDX_CONFIG=/run/buildkit/buildx` keeps builder definitions and client
state private to this sandbox; Docker credentials remain in the home
directory. `podman build` still uses Podman's own builder.

Nested containers can switch to other UIDs, including apt's `_apt` user
and PostgreSQL's UID 999. A nested image still needs its own dependencies:
installing a library in the outer sandbox does not add it to that image.
Install Playwright's dependencies as root while building the service image,
then switch to its runtime user. For example, after installing Playwright:

```dockerfile
RUN npx playwright install --with-deps chromium
USER node
```

This build step needs no `sudo`. For an existing container, Compose's
`exec --user root` can run apt directly. A slim service image may omit sudo
even though the outer sandbox includes it. Use the dependency packages
for that service image's distribution, not the macOS host or outer image.

The sandbox normally uses an executable `/tmp` tmpfs, with `nosuid` and
`nodev`; [filesystem exceptions](security.md#nested-containers) apply.
If a Compose service mounts its own temporary filesystem and needs to
execute files there, use `tmpfs: ["/tmp:rw,nosuid,nodev,exec,size=256m"]`.
The integration test in [test_nested.sh](../test_nested.sh) builds a browser
image, starts PostgreSQL and a web service, and runs Chromium against it.

### Upgrading nested storage

Current stores live under
`~/.local/share/containers/workspaces/<project-hash>/<slot>/`. The hash
uses the physical workspace path, and the lease lasts until that sandbox
exits. `/run/sagent/storage-root` names the selected slot; its
`storage-multiuser` child holds Podman data and `buildkit` holds build cache.

Earlier top-level `storage`, `storage-multiuser` and `buildkit` stores
are retained, not migrated into these slots. Single-UID image layers need
to be pulled or built again to restore their ownership metadata.

Before recreating a database, stop the old service and back up its data.
Recover needed named-volume data from the old store's
`volumes/<name>/_data` into the new named volume, preserving ownership
appropriate for the image. Prefer the database's backup/restore tools
when changing versions or ownership mappings. Bind-mounted project data
stays at its host path.

Do not delete old data until recovery is complete, or remove BuildKit
locks while another sandbox holds them. `reset-caches`, `reset` and an
Ubuntu cache-stamp change can remove the containers volume's contents;
see [cache stamps](storage-layout.md#toolchain-stamps).

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

Choose a version from [releases](https://github.com/e6qu/sclaude/releases)
whose image jobs have completed, and replace `VERSION` below. This runs
Claude Code directly in the published image, without
the wrapper's mounts, limits, capability drops or host state sync:

```bash
image_version=VERSION
docker run --rm -it -v "$PWD:/workspace" -w /workspace \
    "ghcr.io/e6qu/sagent-sandbox:$image_version" claude
```

## Dev containers

| Config | Purpose |
|---|---|
| [`.devcontainer/`](../.devcontainer/) | Develop sclaude itself |
| [`examples/devcontainer-claude/`](../examples/devcontainer-claude/) | Claude Code directly in a project |
| [`examples/devcontainer-sclaude/`](../examples/devcontainer-sclaude/) | Claude Code through sclaude in a project |

What decides the image hash, and how to add a tool, is in
[Contributing](../CONTRIBUTING.md#what-changes-the-image).
