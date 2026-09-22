# Storage layout

Both wrappers share one set of home and cache volumes. Each mounts a config
volume for its own agent. Bind mounts from the host persist as well. On the
host, the wrapper also writes its settings file, the release-check cache
and temporary files, and `install` writes the wrappers and your shell
startup file.

## Volumes and mounts

| Volume | Mounted at | Holds |
|---|---|---|
| `sclaude-config` | `/sclaude-config/` | Claude Code config and credentials |
| `scodex-config` | `/scodex-config/` | Codex auth and config |
| `sagent-rootfs` | `/home/agent/` | Home directory; Go, cargo, Maven and Gradle caches |
| `sagent-npm` | `/home/agent/.npm-global/` | npm global packages |
| `sagent-pip` | `/home/agent/.local/` | pip user packages and scripts |
| `sagent-share` | `/home/agent/.local/share/` | Application data, including uv tools and uv-managed Pythons |
| `sagent-apt-cache` | `/var/cache/apt/` | apt package cache |
| `sagent-apt-lists` | `/var/lib/apt/lists/` | apt package lists |
| `sagent-containers` | `/home/agent/.local/share/containers/` | Nested container images and state |

| Bind mount | Mounted at | Holds |
|---|---|---|
| The workspace | Its own path | The current directory; the physical path mounted at the logical one |
| `~/sagent-drop` | Its own path | Files for the agent; `SAGENT_DROP_DIR` names another folder |
| `SAGENT_EXTRA_MOUNTS` entries | Their own paths | Folders you list; read-only unless marked `:rw` |
| Claude sessions | This workspace's directory under `/sclaude-config/projects/` | Transcripts |
| Codex sessions | `/scodex-config/sessions/` | The whole session tree |
| Clipboard spool | `/run/sagent/clipboard/` | One directory per run under `~/.cache/sagent/` |

`SAGENT_VOLUME_SUFFIX` puts a suffix on every volume name, which selects a
second set of volumes. Bind mounts and image tags stay the same. The test
suite runs on `-e2e` volumes.

## Toolchain stamps

Before each run the helper container checks a `.sagent-stamp` file in each
cache volume against the settings:

- `sagent-npm` records the Node version, because native addons belong to
  one Node ABI.
- `sagent-pip` records the Python version, because packages belong to one
  Python minor.
- The two apt volumes and `sagent-containers` record the Ubuntu release.

When the stamp is missing or differs, the helper clears that volume, says
so, and writes the new stamp. `sclaude reset-caches` clears these volumes
on demand.

## Environment inside the sandbox

- `sclaude` sets `CLAUDE_CONFIG_DIR=/sclaude-config`. `scodex` sets
  `CODEX_HOME=/scodex-config`.
- With Java on, `JAVA_HOME=/opt/java`. With Rust on,
  `RUSTUP_HOME=/opt/rust/rustup`. `CARGO_HOME` is unset, so cargo's
  registry and `cargo install` land in `/home/agent/.cargo`.
- `PATH` puts `~/.npm-global/bin`, `~/.local/bin`, `~/.cargo/bin` and
  `~/go/bin`, all persistent, ahead of the system toolchains.
- `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` points OpenSSL
  clients, the uv-built Python and Codex included, at Ubuntu's bundle.
- `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`: set only when the
  image was built with `SAGENT_CA_BUNDLE`; see
  [corporate proxies](image.md#corporate-proxies).

## Files

### Credentials and configuration

- `/sclaude-config/.credentials.json`: the Claude sign-in. See
  [sign-in and credentials](host-state.md#sign-in-and-credentials) for the
  sources and the replacement rule.
- `/sclaude-config/.claude.json`: Claude Code configuration.
- `/sclaude-config/projects/`: session transcripts. With sharing on, this
  workspace's subdirectory is a bind mount.
- `/sclaude-config/file-history/`: the snapshots `/rewind` restores,
  bind-mounted only with `SAGENT_SESSIONS=all`.
- `/scodex-config/auth.json`: the Codex sign-in.
- `/scodex-config/config.toml`, `instructions.md`, `AGENTS.md`: copies of
  the host files, replaced when the host copy changes. See
  [MCP servers](host-state.md#mcp-servers).

### Home directory

- `~/.config/git/config`: the host's global git config minus host-only keys,
  rewritten every run; `ignore` next to it is the host's excludes file.
- `~/.gitconfig`: sandbox-only git settings, read after the synced file.
- `~/.config/gh/hosts.yml`: one gh token per host, rewritten every run the
  host has a login.
- `~/.ssh/`: with `SAGENT_GIT_PROTOCOL=ssh`, the host's `~/.ssh` files
  (700/600); `.sagent-synced` lists them so the next run replaces exactly
  those.
- `~/.npm-global/`, `~/.local/`, `~/.local/share/`, `~/go/`, `~/.cargo/`,
  `~/.m2/`, `~/.gradle/`: what npm, pip, uv, go, cargo, Maven and Gradle
  install or cache.

### In the image

`/etc/gitconfig` makes gh git's credential helper for github.com and
gist.github.com and sets the git-lfs filters.

## Host state sync

Before each run the wrapper stages what the sandbox gets from the host in
a temporary directory and streams it as one tar over stdin into a root
helper container. The helper writes it into the volumes, owned by your uid,
secrets mode 600. A bind mount of the staging directory would be denied on
SELinux hosts and would break on paths with colons. A failed sync prints a
warning and the run goes on.

[Host state in the sandbox](host-state.md) lists the sources on the host
and the rules for each.

The config volumes and the home volume hold credentials, the gh token, and
with ssh your private keys. Treat a backup of them as sensitive.

## Why volumes

The sandbox is Linux and the host may be macOS. Mounting `~/.claude` or
`~/.npm` from the host would mix two filesystems' ownership rules and two
platforms' binaries. Volumes keep the Linux installs and caches apart from
the host's. What the sandbox needs from the host is copied in. Bind mounts
are for what both sides must see the same way.

## Managing volumes

`sclaude volumes` shows disk use per image and volume.

`sclaude reset-caches` removes the npm, pip, apt and nested-container
volumes. It keeps the config volumes, the home volume and `sagent-share`.

`sclaude reset` removes every volume for the current suffix. Bind mounts
and images stay. Both commands ask first and name any volume a running
container still holds.

The engine's own commands work as well. With podman, replace `docker`.
Append `SAGENT_VOLUME_SUFFIX` when you set one.

```bash
docker volume ls | grep -E 'sagent-|sclaude-|scodex-'
docker volume inspect sclaude-config
docker volume rm sagent-apt-cache
```
