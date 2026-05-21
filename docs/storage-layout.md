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
sagent-rootfs           →  /home/agent/                      Shared home directory & preferences
sagent-npm              →  /home/agent/.npm-global/          Shared npm global packages (Linux)
sagent-pip              →  /home/agent/.local/               Shared pip user packages (Linux)
sagent-apt-cache        →  /var/cache/apt/                   Shared apt package cache
sagent-apt-lists        →  /var/lib/apt/lists/               Shared apt package lists
$(pwd)                  →  $(pwd)                            Current workspace directory
```

## Environment Variables

- `CLAUDE_CONFIG_DIR=/sclaude-config` - Tells Claude Code where to find credentials and configuration
- `CODEX_HOME=/scodex-config` - Tells Codex where to find auth and runtime state

## Key Files and Directories

### Credentials & Configuration
- `/sclaude-config/.credentials.json` - OAuth credentials (auto-synced from macOS Keychain or `~/.claude/.credentials.json` / `$XDG_CONFIG_HOME/claude-code/credentials.json` on Linux)
- `/sclaude-config/.claude.json` - Claude Code configuration
- `/sclaude-config/projects/` - Session history
- `/scodex-config/auth.json` - Codex auth copied from `${CODEX_HOME:-$HOME/.codex}/auth.json`
- `/scodex-config/config.toml` - Codex config copied from `${CODEX_HOME:-$HOME/.codex}/config.toml` when present

### User Files
- `/home/agent/` - Shared user home directory (theme preferences, CLI state, etc.)

### Package Management
- `/home/agent/.npm-global/` - npm global packages
- `/home/agent/.local/` - pip user packages
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
- **Solution**: Mount workspace at same absolute path in container

## Security

Docker volumes provide strong isolation while allowing persistence:

- ✅ Volumes isolated from host filesystem
- ✅ Cannot access files outside mounted workspace
- ✅ Starts as a non-root user
- ✅ Capabilities limited to the set needed for package management
- ✅ Resource limits enforced (4GB RAM, 2 CPUs, 100 PIDs)
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
docker volume rm sclaude-config scodex-config sagent-rootfs sagent-npm sagent-pip sagent-apt-cache sagent-apt-lists
```
