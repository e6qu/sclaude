# Storage layout

What persists between runs lives in named volumes: one set of home and cache
volumes shared by both wrappers, and a config volume per tool for its
credentials. On the host, only the workspace, the drop folder, the shared
session directory and the clipboard spool are written to.

## Volumes

| Volume | Mounted at | Holds |
|---|---|---|
| `sclaude-config` | `/sclaude-config/` | Claude Code config and credentials |
| `scodex-config` | `/scodex-config/` | Codex auth and config |
| `sagent-rootfs` | `/home/agent/` | Home directory; Go, cargo, Maven and Gradle caches |
| `sagent-npm` | `/home/agent/.npm-global/` | npm global packages |
| `sagent-pip` | `/home/agent/.local/` | pip user packages and scripts |
| `sagent-share` | `/home/agent/.local/share/` | uv tools and uv-managed Pythons; not a cache |
| `sagent-apt-cache` | `/var/cache/apt/` | apt package cache |
| `sagent-apt-lists` | `/var/lib/apt/lists/` | apt package lists |
| `sagent-containers` | `/home/agent/.local/share/containers/` | Nested container images and state |
| the workspace | its own path | The current directory; physical path mounted at the logical one |
| `~/sagent-drop` | its own path | Files for the agent; `SAGENT_DROP_DIR` names another folder |

`SAGENT_VOLUME_SUFFIX` puts a suffix on every volume name, which gives a
second, separate set of sandbox state. The test suite runs on `-e2e`
volumes and never touches yours.

## Toolchain stamps

Each cache volume carries a `.sagent-stamp` file naming the toolchain it was
filled for: `node=26`, `python=3.14`, `ubuntu=26.04`. Before every run the
helper container compares the stamp with the image and, when they differ,
clears the volume and says so. pip packages belong to one Python minor
version, npm native addons to one Node ABI, and apt and podman state to one
Ubuntu release. A volume without a stamp is treated the same way once.
`sclaude reset-caches` clears these volumes on demand.

## Environment inside the sandbox

- `CLAUDE_CONFIG_DIR=/sclaude-config` and `CODEX_HOME=/scodex-config`: where
  each CLI keeps credentials and state.
- `JAVA_HOME=/opt/java`, `RUSTUP_HOME=/opt/rust/rustup`: the system JDK and
  rustup. `CARGO_HOME` is unset, so cargo's registry and `cargo install`
  land in `/home/agent/.cargo`.
- `PATH` puts `~/.npm-global/bin`, `~/.local/bin`, `~/.cargo/bin` and
  `~/go/bin`, all persistent, ahead of the system toolchains.
- `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`: the uv-built Python's
  OpenSSL expects `/etc/ssl/cert.pem`, which Ubuntu lacks; Codex reads it
  too.
- `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`: set only when the
  image was built with `SAGENT_CA_BUNDLE`; see
  [corporate proxies](image.md#corporate-proxies).

## Files

Credentials and configuration:

- `/sclaude-config/.credentials.json`: Claude sign-in, from the macOS
  keychain or `~/.claude/.credentials.json` on Linux.
- `/sclaude-config/.claude.json`: Claude Code configuration.
- `/sclaude-config/projects/`: session transcripts, bind-mounted from the
  host.
- `/sclaude-config/file-history/`: the snapshots `/rewind` restores,
  bind-mounted only with `SAGENT_SESSIONS=all`.
- `/scodex-config/auth.json`, `config.toml`, `instructions.md`, `AGENTS.md`:
  from `${CODEX_HOME:-$HOME/.codex}`. `config.toml` is copied again only
  when the host file changes, so `scodex mcp add` inside survives.

Home directory:

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

In the image: `/etc/gitconfig` makes gh git's credential helper for
github.com and sets the git-lfs filters. `/run/sagent/clipboard/` is the
per-run clipboard spool, mounted from `~/.cache/sagent/clipboard.*`.

## Host state sync

Before every run the wrapper stages what the sandbox gets from the host and
streams it as one tar over stdin into a root helper container, which writes
it into the volumes owned by your uid, secrets mode 600. A tar over stdin
rather than a bind mount, because a host bind mount is denied on SELinux
hosts and breaks on paths with colons.

| What | Source on the host |
|---|---|
| Claude sign-in | macOS keychain, or `~/.claude/.credentials.json` or `$XDG_CONFIG_HOME/claude-code/credentials.json` on Linux |
| Codex sign-in and config | `${CODEX_HOME:-$HOME/.codex}`: `auth.json`, `config.toml`, `instructions.md`, `AGENTS.md` |
| git | `git config --global --includes --list`, filtered, plus the excludes file |
| gh | `gh auth token --hostname H` per host in `hosts.yml` |
| ssh | with `SAGENT_GIT_PROTOCOL=ssh`, `~/.ssh`; `config` loses `UseKeychain` and `$HOME` becomes `~` |

Sign-in files are copied only when the host copy is newer than the one in
the volume: Claude by `expiresAt`, Codex by `last_refresh`. Refresh tokens
rotate and the sandbox refreshes on its own, so an older host copy over a
newer sandbox one would be a logout.

`sclaude-config`, `scodex-config` and `sagent-rootfs` hold secrets:
credentials, the gh token, and with ssh your private keys.

## Why volumes rather than host directories

The sandbox is Linux and the host may be macOS. Mounting `~/.claude` or
`~/.npm` from the host would mix two filesystems' ownership rules and two
platforms' binaries. Volumes hold Linux-shaped state; what the sandbox
needs from the host is copied in, and only what both sides must see the
same way is bind-mounted: the workspace, the drop folder and the session
transcripts.

## Managing volumes

`sclaude volumes` shows disk use per image and volume. `sclaude
reset-caches` clears the cache volumes and keeps credentials and the home
directory. `sclaude reset` deletes everything. The engine's own commands
work too:

```bash
docker volume ls | grep -E 'sagent-|sclaude-|scodex-'
docker volume inspect sclaude-config
docker volume rm sagent-apt-cache
```
