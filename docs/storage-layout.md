# sclaude / scodex Storage Layout

## Docker Volume Architecture

sclaude and scodex use Docker named volumes for persistent storage, providing
clean separation from the host filesystem and proper Linux file structure
compatibility. Both scripts share one Docker image and shared package/home
volumes, while credentials stay in tool-specific volumes.

## Volume Structure

```
Docker Volume              Container Mount                   Purpose
─────────────────────────  ────────────────────────────────  ────────────────────────────────
sclaude-config          →  /sclaude-config/                  Claude Code config & credentials
scodex-config           →  /scodex-config/                   Codex auth and config
sagent-rootfs           →  /home/agent/                      Shared home directory & preferences; Go, cargo, Maven/Gradle caches
sagent-npm              →  /home/agent/.npm-global/          Shared npm global packages
sagent-pip              →  /home/agent/.local/               Shared pip user packages, uv-managed Pythons, pip scripts
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

## Environment Variables

- `CLAUDE_CONFIG_DIR=/sclaude-config` - Tells Claude Code where to find credentials and configuration
- `JAVA_HOME=/opt/java`, `RUSTUP_HOME=/opt/rust/rustup` - System-wide JDK and rustup toolchain; `CARGO_HOME` is unset so cargo's registry and `cargo install` land in `/home/agent/.cargo`
- `PATH` puts `~/.npm-global/bin`, `~/.local/bin`, `~/.cargo/bin` and `~/go/bin` (all persistent) ahead of the system toolchains in `/usr/local/go/bin`, `/opt/rust/cargo/bin` and `/opt/java/bin`
- `CODEX_HOME=/scodex-config` - Tells Codex where to find auth and runtime state
- `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` - Always set: the uv-built Python's OpenSSL expects `/etc/ssl/cert.pem`, which Ubuntu lacks; Codex reads it too
- `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `PIP_CERT` - Set only when the image was built with `SAGENT_CA_BUNDLE`; they point Node, requests and pip at the extra trust anchors (see the README's corporate-network section)

## Key Files and Directories

### Credentials & Configuration
- `/sclaude-config/.credentials.json` - OAuth credentials (auto-synced from macOS Keychain or `~/.claude/.credentials.json` / `$XDG_CONFIG_HOME/claude-code/credentials.json` on Linux)
- `/sclaude-config/.claude.json` - Claude Code configuration
- `/sclaude-config/projects/` - Session history
- `/scodex-config/auth.json` - Codex auth copied from `${CODEX_HOME:-$HOME/.codex}/auth.json`
- `/scodex-config/config.toml` - Codex config copied from `${CODEX_HOME:-$HOME/.codex}/config.toml` when present
- `/scodex-config/instructions.md` - Codex instructions copied from `${CODEX_HOME:-$HOME/.codex}/instructions.md` when present
- `/scodex-config/AGENTS.md` - Codex agent guide copied from `${CODEX_HOME:-$HOME/.codex}/AGENTS.md` when present

### User Files
- `/home/agent/` - Shared user home directory (theme preferences, CLI state, etc.)

### Package Management
- `/home/agent/.npm-global/` - npm global packages
- `/home/agent/.local/` - pip user packages, uv-managed Pythons (`uv python install` as the agent)
- `/home/agent/go/` - Go module cache and `go install` binaries
- `/home/agent/.cargo/` - cargo registry and `cargo install` binaries
- `/home/agent/.m2/`, `/home/agent/.gradle/` - Maven and Gradle caches (projects' `mvnw`/`gradlew` wrappers download into them)
- `/var/cache/apt/` - apt package cache
- `/var/lib/apt/lists/` - apt package lists

## Credential Sync Flow

sclaude and scodex sync credentials from the host into Docker volumes on each run:

**macOS**: Extracts OAuth token from Keychain (`security find-generic-password`)
**Linux**: Reads from `~/.claude/.credentials.json` or `$XDG_CONFIG_HOME/claude-code/credentials.json`
**Codex**: Reads from `${CODEX_HOME:-$HOME/.codex}/auth.json` and common config files

1. Reads credentials from host (Keychain on macOS, file on Linux)
2. Validates JSON integrity inside the container
3. Writes to the tool-specific config volume and copies Codex config files when present
4. Sets `CLAUDE_CONFIG_DIR=/sclaude-config` or `CODEX_HOME=/scodex-config`
5. Credentials persist in the Docker volume across container restarts

These config volumes contain secrets. Treat `sclaude-config` and
`scodex-config` as sensitive; `scodex-config/auth.json` is password-equivalent,
and `config.toml` can contain private provider or endpoint details.

## Why This Design?

### Problem 1: Credential Persistence
- Credentials must persist across container restarts
- macOS stores credentials in Keychain, Linux uses files
- Container can't access macOS Keychain
- **Solution**: Auto-sync from Keychain to Docker volume on each run

### Problem 2: macOS vs Linux File Structure
- macOS and Linux have different file layouts and permissions
- Mounting host directories caused permission/ownership conflicts
- **Solution**: Use Docker volumes for Linux filesystem, sync only what's needed

### Problem 3: Package Isolation
- macOS and Linux packages are incompatible architectures
- Don't want conflicts with host packages
- **Solution**: Separate Docker volumes for Linux packages (npm, pip, apt cache)

### Problem 4: Session Sharing
- Want `--resume` to work across container runs
- Sessions stored per-directory path
- **Solution**: Mount the workspace at the same absolute (logical) path in the container

## Security

Docker volumes provide strong isolation while allowing persistence:

- ✅ Volumes isolated from host filesystem
- ✅ Cannot access files outside mounted workspace
- ✅ Starts as a non-root user
- ✅ Capabilities limited to the set needed for package management
- ✅ Resource limits enforced (4GB RAM, 2 CPUs, 100 PIDs; 512 PIDs with container tooling)
- ✅ Ephemeral container (`--rm` flag, filesystem reset on exit)
- ✅ Workspace sandboxed to current directory only

## Volume Management

### View Volumes

```bash
sclaude volumes
```

### Reset All Data

```bash
# Deletes ALL persistent data (credentials, packages, preferences)
sclaude reset
```

### Manual Volume Management

```bash
# List volumes
docker volume ls | grep -E 'sagent-|sclaude-|scodex-'

# Inspect a specific volume
docker volume inspect sclaude-config

# Remove specific volume
docker volume rm sagent-apt-cache

# Remove all sclaude volumes
docker volume rm sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-apt-cache sagent-apt-lists sagent-containers
```
