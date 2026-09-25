# Security

The wrappers run the agent in a container with dropped capabilities and
resource limits. The agent keeps network access and can read and change
what is mounted or copied in. This page lists what the container isolates,
what it lets through on purpose, and the settings that narrow it.

## What it protects against

- Direct access to host files outside the mounted directories.
- The agent reaching the host engine, other containers, or host services
  through `localhost`.
- An ordinary process reaching the host through the container's user and
  filesystem namespaces.
- Memory, CPU, process and file descriptor use beyond the configured
  limits.

## What it does not protect against

- Harmful actions within the agent's reach, whether you asked for them or
  the code it reads induced them.
- Exfiltration of the workspace and of what is synced in. The agent needs
  the network for packages and its API.
- Unknown container escapes in the kernel or the engine.
- Malicious packages the agent installs. They run inside the sandbox with
  the agent's reach.

## Isolation

### Filesystem

The wrapper mounts the workspace and the drop folder read-write at their
own paths, and the folders in `SAGENT_EXTRA_MOUNTS` read-only unless an
entry is marked `:rw`. With sharing on, it also mounts the session directories and the
per-run clipboard spool, and with `SAGENT_SESSIONS=all` Claude's
`file-history`. Everything else the sandbox sees is a named volume or a
copy. The workspace source is the physical path, with symlinks resolved,
and `/` is refused. `..` from a bind mount lands in the container's own
filesystem.

On rootless podman the wrapper adds `--userns=keep-id`. The sandbox user is
then your user on the host side, and every other uid, root included, stays
in your subordinate range. The docker CLI cannot request that mapping, so a
rootless daemon behind it is refused.

Toolchains in the image are owned by root. The agent user cannot write
them, except `RUSTUP_HOME`, which rustup's proxies write to. User-level
installs (`pip --user`, `npm -g`, `cargo install`, `go install`, `uv python
install`) go to the persistent home volumes.

### User and sudo

Everything runs as `agent`, with your uid and gid, so files in the
workspace keep their owner. A helper container runs as root before each
session to fill the volumes.

`sudo` is limited to `apt-get`, `apt` and `dpkg`, without a password, so
the agent can install system packages. Package scripts and apt hooks run as
root inside the container, so those three commands amount to root there,
within the container's remaining limits. `no-new-privileges` is left unset
because it would break `sudo apt`.

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

The defaults are 8 GB of memory, 4 CPUs and 8192 file descriptors. The
process limit is 100, or 512 with nested containers on. `MEMORY_LIMIT`,
`CPU_LIMIT`, `PIDS_LIMIT` and `PIDS_LIMIT_NESTED` in the settings file
change them. The file descriptor limit is fixed.

On macOS the engine's VM is the ceiling. A Docker daemon refuses a CPU
limit above its CPU count, so the wrapper stops when `CPU_LIMIT` is higher
than the VM's CPUs. Colima and Rancher Desktop start with 2. Give the VM
more CPUs, or set `CPU_LIMIT` to the VM's count. A memory limit above the
VM's memory is accepted but never reached.

### Network

`--network bridge` gives an isolated network namespace with outbound
access. The container's `localhost` is its own. Host services may still be
reachable through the engine's gateway address or Docker Desktop's host
aliases.

### Engine socket

The wrapper never mounts the engine socket. `docker` and `podman` inside
run through nested podman. `/var/run/docker.sock` inside is podman's own API
socket at `/run/podman/podman.sock`, served by a process in the sandbox as
the sandbox user, for docker compose, the Docker SDKs and testcontainers. It
reaches only the nested containers. A daemon that listens on the network,
or a socket inside a mounted directory, is a separate exposure.

### Nested containers

Container tooling inside the sandbox is on by default. It runs through a
rootless podman inside the container, with images in the
`sagent-containers` volume. The mode adds no capabilities beyond the set
above. The single-uid mapping means the privileged `newuidmap` path is
never used.

The mode changes four run options:

- The default seccomp profile is off, because it blocks the nested mount
  and user-namespace syscalls.
- The AppArmor profile is off on hosts that enforce one.
- `/dev/fuse` and `/dev/net/tun` are passed in.
- The process limit is `PIDS_LIMIT_NESTED`, 512 by default.

`/proc/sys` stays read-only. netavark, which sets up the nested bridge
networks, writes a few per-interface sysctls such as `route_localnet`. The
image runs it in a private mount namespace where those files are on a
tmpfs, so the writes change nothing outside it. `ip_forward` there is the
real, read-only file. Stopping a nested container signals its own
processes: a crun wrapper replaces `kill --all`, which on cgroup v2 would
signal the sandbox's whole cgroup, since nested containers share it.

That is more kernel surface. `SAGENT_DOCKER=0` or `--no-docker` runs with
the default profiles, no extra devices and `PIDS_LIMIT`. Nested containers
share the sandbox's PID namespace and use single-uid storage, so images
that rely on multi-user file ownership may behave differently.

### Ephemeral container

The engine removes the container on exit. The volumes and the bind mounts
persist. Packages installed into the container's system directories are
gone on the next run.

### `sclaude shell`

A fresh `shell` runs bash with the tool container's mounts, capabilities
and limits. When a sandbox is already running for the workspace, `shell`
attaches to that container and gets whatever confinement it started with.

## What is let through on purpose

Each item here is a choice. [Host state in the sandbox](host-state.md)
describes the mechanics and the settings.

### Secrets

Forwarded when set in your environment: `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`,
`CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN` for sclaude; `OPENAI_API_KEY`,
`CODEX_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_ORGANIZATION`, `OPENAI_PROJECT`,
`CODEX_ACCESS_TOKEN` and `GH_TOKEN` for scodex; and the terminal identity
variables.

Synced in: the sign-in of the agent you run, your `gh` login, your global
git config. With `SAGENT_GIT_PROTOCOL=ssh`, the default when your gh uses
ssh, also `~/.ssh` with your private keys. Those keys open every host they
open on your machine. Whatever the agent can read it can send out.
`SAGENT_GIT_PROTOCOL=https` keeps the keys out. Use a fine-grained `gh`
token when the full one should not travel. Logging out on the host leaves
the token already in the volume until `sclaude reset`.

The wrapper does not forward host certificate paths such as
`SSL_CERT_FILE`. Use `SAGENT_CA_BUNDLE` to add certificates to the image.

### Session transcripts

This workspace's Claude Code transcripts, and Codex's whole session tree,
are bind-mounted from the host so either side can resume the other's work.
The agent can read and write them. `SAGENT_SESSIONS=0` keeps them out.
`SAGENT_SESSIONS=all` also shares `~/.claude/file-history`, which holds
file contents from every workspace.

### Clipboard

With the bridge on, the agent can read your clipboard at any time and set
it to anything, text or a PNG. A helper on the host serves the requests
through a private per-run spool directory. `SAGENT_CLIPBOARD=0` turns the
bridge off. Copies can still reach the host through OSC 52 when the
terminal allows it. See [clipboard](host-state.md#clipboard).

### The drop folder

`~/sagent-drop` is read-write for the agent. Keep it for files you mean to
hand over. `SAGENT_DROP_DIR` points it elsewhere.

### Extra mounts

The agent can read everything in a folder listed in `SAGENT_EXTRA_MOUNTS`,
and with `:rw` change or delete it. Do not list your home directory or a
folder that holds keys or tokens.

### Extra trust anchors

The image trusts the certificates in `SAGENT_CA_BUNDLE`, and Node,
OpenSSL, requests and pip are pointed at them. Whoever controls one of
those CAs and sits on the path can impersonate any HTTPS endpoint and read
credentials in flight. The auto-detected bundle is the host's exported
trust store, which holds more than the proxy's certificate. A bundle you
name can add trust the host itself does not have.

## What you can tighten

| Setting | Effect |
|---|---|
| `SAGENT_DOCKER=0` | Default seccomp and AppArmor, no `/dev/fuse` or `/dev/net/tun`, `PIDS_LIMIT` |
| `SAGENT_GIT_PROTOCOL=https` | No SSH keys enter the sandbox. Keys copied on an earlier run are removed |
| `SAGENT_SESSIONS=0` | No transcript mounts |
| `SAGENT_CLIPBOARD=0` | No clipboard bridge. OSC 52 copies remain |
| `MEMORY_LIMIT`, `CPU_LIMIT`, `PIDS_LIMIT`, `PIDS_LIMIT_NESTED` | Lower limits, set in the settings file |

The wrapper has no option for a run without network, a read-only
workspace, another runtime such as gVisor, or extra `docker run` flags.

## Working safely

Commit before a run and review with `git diff` afterwards. Keep secrets out
of the workspace. Do not point the sandbox at a codebase you do not trust.
The code it contains runs with the agent's reach.
