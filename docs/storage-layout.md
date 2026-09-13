# Storage layout

What persists between runs lives in named volumes: one image and one set of
home and cache volumes for both wrappers, and a config volume per tool for its
credentials. Nothing is written to the host except the workspace, the shared
session directory and the clipboard spool.

## Volumes

```
Docker Volume              Container Mount                   Purpose
─────────────────────────  ────────────────────────────────  ────────────────────────────────
sclaude-config          →  /sclaude-config/                  Claude Code config & credentials
scodex-config           →  /scodex-config/                   Codex auth and config
sagent-rootfs           →  /home/agent/                      Shared home directory & preferences; Go, cargo, Maven/Gradle caches
sagent-npm              →  /home/agent/.npm-global/          Shared npm global packages
sagent-pip              →  /home/agent/.local/                Shared pip user packages and pip scripts
sagent-share            →  /home/agent/.local/share/          uv tools, uv-managed Pythons, other XDG data (not a cache)
sagent-apt-cache        →  /var/cache/apt/                   Shared apt package cache
sagent-apt-lists        →  /var/lib/apt/lists/               Shared apt package lists
sagent-containers       →  /home/agent/.local/share/containers/  Nested container images/state (--docker mode)
$(pwd -P)               →  $(pwd)                            Current workspace directory (physical path mounted at the logical path)
```

## Toolchain stamps

The cache volumes (`sagent-npm`, `sagent-pip`, `sagent-apt-cache`,
`sagent-apt-lists`, `sagent-containers`) each carry a `.sagent-stamp` file
naming the toolchain they were filled for (`node=26`, `python=3.14`,
`ubuntu=26.04`). The helper container that runs before every sandbox launch
compares the stamp with the image's toolchain and, when they differ, clears
the volume's contents and prints a warning: pip site-packages are per Python
minor version, npm native addons are built against one Node ABI, and apt and
podman state belong to one Ubuntu release. A volume without a stamp (created
by an older wrapper) is treated the same way once. Nothing else needs to be
run after a version change; `sclaude volumes` shows usage and
`sclaude reset-caches` clears these volumes on demand.

## Environment variables

- `CLAUDE_CONFIG_DIR=/sclaude-config` - Tells Claude Code where to find credentials and configuration
- `JAVA_HOME=/opt/java`, `RUSTUP_HOME=/opt/rust/rustup` - System-wide JDK and rustup toolchain; `CARGO_HOME` is unset so cargo's registry and `cargo install` land in `/home/agent/.cargo`
- `PATH` puts `~/.npm-global/bin`, `~/.local/bin`, `~/.cargo/bin` and `~/go/bin` (all persistent) ahead of the system toolchains in `/usr/local/go/bin`, `/opt/rust/cargo/bin` and `/opt/java/bin`
- `CODEX_HOME=/scodex-config` - Tells Codex where to find auth and runtime state
- `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` - Always set: the uv-built Python's OpenSSL expects `/etc/ssl/cert.pem`, which Ubuntu lacks; Codex reads it too
- `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `PIP_CERT` - Set only when the image was built with `SAGENT_CA_BUNDLE`; they point Node, requests and pip at the extra trust anchors (README, "Corporate networks")

## Key files and directories

### Credentials and configuration
- `/sclaude-config/.credentials.json` - OAuth credentials (auto-synced from macOS Keychain or `~/.claude/.credentials.json` / `$XDG_CONFIG_HOME/claude-code/credentials.json` on Linux)
- `/sclaude-config/.claude.json` - Claude Code configuration
- `/sclaude-config/projects/` - Session history (bind-mounted from the host)
- `/sclaude-config/file-history/` - Snapshots `/rewind` restores (bind-mounted only with `SAGENT_SESSIONS=all`)
- `/scodex-config/auth.json` - Codex auth copied from `${CODEX_HOME:-$HOME/.codex}/auth.json`
- `/scodex-config/config.toml` - Codex config copied from `${CODEX_HOME:-$HOME/.codex}/config.toml` when present, and again only when that file changes (`.sagent-synced-config.toml` holds its hash), so `scodex mcp add` inside survives
- `/scodex-config/instructions.md` - Codex instructions copied from `${CODEX_HOME:-$HOME/.codex}/instructions.md` when present
- `/scodex-config/AGENTS.md` - Codex agent guide copied from `${CODEX_HOME:-$HOME/.codex}/AGENTS.md` when present

### User files
- `/home/agent/` - Shared user home directory (theme preferences, CLI state, etc.)
- `/home/agent/.config/git/config` - host global git config minus host-only keys, rewritten every run; `ignore` next to it is the host's excludes file
- `/home/agent/.gitconfig` - sandbox-only git settings; read after the synced file, so it wins
- `/home/agent/.config/gh/hosts.yml` - gh token per host, rewritten every run the host has a login
- `/home/agent/.ssh/` - with `SAGENT_GIT_PROTOCOL=ssh`, the host's `~/.ssh` files (700/600); `.sagent-synced` lists them so the next run replaces exactly those
- `/run/sagent/clipboard/` - per-run clipboard bridge spool, mounted from `~/.cache/sagent/clipboard.*`
- `/etc/gitconfig` (image) - gh as git's credential helper for github.com, git-lfs filters

### Package management
- `/home/agent/.npm-global/` - npm global packages
- `/home/agent/.local/` - pip user packages and scripts
- `/home/agent/.local/share/` - what `uv tool install` installs and the Pythons uv manages, in their own volume: the pip volume around it is cleared when the image Python changes, and neither belongs to that Python. Content left in the old location moves here on the next run
- `/home/agent/go/` - Go module cache and `go install` binaries
- `/home/agent/.cargo/` - cargo registry and `cargo install` binaries
- `/home/agent/.m2/`, `/home/agent/.gradle/` - Maven and Gradle caches (projects' `mvnw`/`gradlew` wrappers download into them)
- `/var/cache/apt/` - apt package cache
- `/var/lib/apt/lists/` - apt package lists

## Host state sync

sclaude and scodex carry credentials and host state into Docker volumes on each run:

**macOS**: Extracts OAuth token from Keychain (`security find-generic-password`)
**Linux**: Reads from `~/.claude/.credentials.json` or `$XDG_CONFIG_HOME/claude-code/credentials.json`
**Codex**: Reads from `${CODEX_HOME:-$HOME/.codex}/auth.json` and common config files
**git**: `git config --global --includes --list`, filtered, plus the excludes file
**gh**: `gh auth token --hostname H` per host in `hosts.yml` (`GH_TOKEN` masked for the lookup)
**ssh**: with `SAGENT_GIT_PROTOCOL=ssh`, `~/.ssh`; `config` loses `UseKeychain`, `$HOME` becomes `~`

1. Stage everything in a temporary directory on the host
2. Stream it as a tar over stdin into a root helper container (no host bind mount: SELinux, colons in paths)
3. Validate the credentials are JSON
4. Write to the config volume and the home volume, owned by your UID, secrets 600

`sclaude-config`, `scodex-config` and `sagent-rootfs` hold secrets:
credentials, the gh token, with ssh your private keys.

## Why volumes rather than host directories

The sandbox is Linux and the host may be macOS: mounting `~/.claude` or
`~/.npm` from the host would mix two filesystems' ownership rules and two
platforms' binaries. Volumes hold Linux-shaped state, and only what the
sandbox needs from the host is copied in each run (credentials, git and gh
state) or bind-mounted where both sides must see the same files (the
workspace, mounted at its own path so per-directory state keys match, and
the session transcripts — see the README, "Sessions are shared").

## Volume management

### View volumes

```bash
sclaude volumes
```

### Reset all data

Deletes all persistent data — credentials, packages, preferences:

```bash
sclaude reset
```

### By hand

List, inspect or remove the volumes directly:

```bash
docker volume ls | grep -E 'sagent-|sclaude-|scodex-'
docker volume inspect sclaude-config
docker volume rm sagent-apt-cache
```

Remove all of them:

```bash
docker volume rm sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-share sagent-apt-cache sagent-apt-lists sagent-containers
```
