# Security

What the sandbox isolates, what it lets through on purpose, and the settings
that narrow it. The sandbox is a container with dropped capabilities and
resource limits. It is not a VM, and it has network access.

## What it protects against

- The agent reading or changing files outside the workspace.
- The agent reaching the host engine, other containers, or host services
  through `localhost`.
- The agent gaining root on the host, or broad root inside the container.
- Runaway resource use: memory, CPU, processes, file descriptors.

## What it does not protect against

- A user who deliberately runs harmful tasks.
- Exfiltration of the workspace and of what is synced in. The agent needs
  the network for packages and its API.
- Unknown container escapes in the kernel or the engine.
- Malicious packages the agent installs. They run inside the sandbox with
  the agent's reach.

## Isolation

### Filesystem

The current directory is bind-mounted read-write at the same path. The
physical path, with symlinks resolved, is the source. `/` is refused as a
workspace. `~/sagent-drop`, or the folder `SAGENT_DROP_DIR` names, is
mounted read-write at its own path. Everything else the sandbox sees is a
named volume or a copy. No other host directory is mounted, and `..` cannot
leave a bind mount.

On rootless podman the wrapper adds `--userns=keep-id`. The sandbox user is
then your user on the host side, and every other uid, root included, stays
in your subordinate range. The docker CLI cannot request that mapping, so a
rootless daemon behind it is refused.

Toolchains in the image are owned by root and read-only for the agent,
except `RUSTUP_HOME`, which rustup's proxies write to. User-level installs
(`pip --user`, `npm -g`, `cargo install`, `go install`, `uv python install`)
go to the persistent home volumes.

### User and sudo

Everything runs as `agent`, with your uid and gid, so files in the
workspace keep their owner. `sudo` is limited to `apt-get`, `apt` and
`dpkg`, without a password, so the agent can install system packages.
`no-new-privileges` is not set because it would break `sudo apt`. The
trade-off is root inside the container for those three commands.

### Capabilities

All capabilities are dropped, then the set `apt` needs is added back:
`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`, `SETGID`, `SETUID`,
`SYS_CHROOT`, and `NET_BIND_SERVICE` for low ports. `SYS_ADMIN`,
`SYS_PTRACE`, `NET_ADMIN`, `SYS_MODULE` and `MKNOD` are not granted.

The container runs with `--security-opt label=disable`. On SELinux hosts the
workspace mount would otherwise be unreadable without relabelling your
files. SELinux confinement is not part of this sandbox's model. The flag is
a no-op elsewhere.

### Resource limits

`--memory 4g`, `--cpus 2`, `--pids-limit 100` (512 with container
tooling), `--ulimit nofile=8192`. `MEMORY_LIMIT`, `CPU_LIMIT` and
`PIDS_LIMIT` change them.

### Network

`--network bridge` gives an isolated network namespace with outbound
access. The container's `localhost` is its own. Host services may still be
reachable through the engine's gateway address or Docker Desktop's host
aliases.

### Engine socket

The engine socket is never mounted. Nothing the agent does with `docker` or
`podman` reaches the host daemon.

### Nested containers

Container tooling inside the sandbox is on by default. It runs through a
rootless podman inside the container, with images in the
`sagent-containers` volume. Capabilities stay dropped. The single-uid
mapping means the privileged `newuidmap` path is never used.

The mode relaxes four things. The default seccomp profile is off, because
it blocks the nested mount and user-namespace syscalls. The AppArmor
profile is off on hosts that enforce one. `/dev/fuse` and `/dev/net/tun`
are passed in. The PID limit is 512. That is more kernel surface than a
hardened run. `SAGENT_DOCKER=0` or `--no-docker` runs with the default
profiles and no extra devices. Nested containers share the sandbox's PID
namespace and use single-uid storage, so images that rely on multi-user
file ownership may behave differently.

### Ephemeral container

The container is removed on exit. The volumes and the workspace persist.

### `sclaude shell`

`shell` runs bash with the tool container's mounts, capabilities and
limits, or attaches to the sandbox already running for the workspace. It
has the same confinement as a session.

## What is let through on purpose

Each item here is a choice, and each has a setting that turns it off.
[Host state in the sandbox](host-state.md) describes the mechanics.

### Secrets

Forwarded when set in your environment: `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`,
`CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN` for sclaude; `OPENAI_API_KEY`,
`CODEX_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_ORGANIZATION`, `OPENAI_PROJECT`,
`CODEX_ACCESS_TOKEN` and `GH_TOKEN` for scodex; and the terminal identity
variables.

Synced in: your Claude and Codex sign-in, your `gh` login, your global git
config. With `SAGENT_GIT_PROTOCOL=ssh`, the default when your gh uses ssh,
also `~/.ssh` with your private keys. Those keys open every host they open
on your machine. Whatever the agent can read it can send out.
`SAGENT_GIT_PROTOCOL=https` keeps the keys out. Logging `gh` out on the
host, or using a fine-grained token, limits what the token can do.

Host paths do not exist in the sandbox, so `SSL_CERT_FILE` and similar are
not forwarded. Use `SAGENT_CA_BUNDLE`.

### Session transcripts

This workspace's Claude Code transcripts, and Codex's whole session tree,
are bind-mounted from the host so either side can resume the other's work.
The agent can read and write them. `SAGENT_SESSIONS=0` keeps them out.
`SAGENT_SESSIONS=all` also shares `~/.claude/file-history`, which holds
file contents from every workspace. Nothing else the tools keep on the host
is mounted.

### Clipboard

The sandbox's clipboard commands, and its X display, are served by an agent
on the host through a per-run spool directory (`~/.cache/sagent/clipboard.*`,
mode 700, removed afterwards). Request data is clipboard content, text or a
PNG. The agent can read your clipboard at any time and set it to anything.
`SAGENT_CLIPBOARD=0` turns the bridge off.

### The drop folder

`~/sagent-drop` is read-write for the agent. Keep it for files you mean to
hand over. `SAGENT_DROP_DIR` points it elsewhere.

### Extra trust anchors

Certificates in `SAGENT_CA_BUNDLE` go into the image's trust store and are
exported to Node, OpenSSL, requests and pip. Whoever controls that CA can
read the sandbox's HTTPS traffic, credentials in flight included. The same
is already true of the host on such a network.

## What you can tighten

| Setting | Effect |
|---|---|
| `SAGENT_DOCKER=0` | No nested containers: default seccomp and AppArmor, no `/dev/fuse` or `/dev/net/tun`, PID limit 100 |
| `SAGENT_GIT_PROTOCOL=https` | No SSH keys enter the sandbox |
| `SAGENT_SESSIONS=0` | No transcripts shared |
| `SAGENT_CLIPBOARD=0` | The sandbox cannot read or set the host clipboard |
| `MEMORY_LIMIT`, `CPU_LIMIT`, `PIDS_LIMIT` | Lower than 4g, 2 and 100 |

Not available: a run without network, a read-only workspace, another
runtime such as gVisor, or extra `docker run` flags. Log `gh` out on the
host if the token should not travel.

## Working safely

Commit before a run and review with `git diff` afterwards. Keep secrets out
of the workspace. Do not point the sandbox at a codebase you do not trust.
The code it contains runs with the agent's reach.
