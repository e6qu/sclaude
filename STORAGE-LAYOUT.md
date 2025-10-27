# sclaude Storage Layout

## Docker Volume Architecture

sclaude uses Docker named volumes for persistent storage, providing clean separation from the host filesystem and proper Linux file structure compatibility.

## Volume Structure

```
Docker Volume              Container Mount                   Purpose
─────────────────────────  ────────────────────────────────  ────────────────────────────────
sclaude-config          →  /sclaude-config/                  Claude Code config & credentials
sclaude-rootfs          →  /home/claude/                     Home directory & preferences
sclaude-npm             →  /home/claude/.npm-global/         npm global packages (Linux)
sclaude-pip             →  /home/claude/.local/              pip user packages (Linux)
sclaude-apt             →  /var/cache/apt/                   apt package cache
$(pwd)                  →  $(pwd)                            Current workspace directory
```

## Environment Variables

- `CLAUDE_CONFIG_DIR=/sclaude-config` - Tells Claude Code where to find credentials and configuration

## Key Files and Directories

### Credentials & Configuration
- `/sclaude-config/.credentials.json` - OAuth credentials (auto-synced from macOS Keychain)
- `/sclaude-config/.claude.json` - Claude Code configuration
- `/sclaude-config/projects/` - Session history

### User Files
- `/home/claude/` - User home directory (theme preferences, etc.)

### Package Management
- `/home/claude/.npm-global/` - npm global packages
- `/home/claude/.local/` - pip user packages
- `/var/cache/apt/` - apt package cache

## Credential Sync Flow

On macOS, credentials are stored in Keychain. sclaude automatically:

1. Extracts OAuth token from macOS Keychain on each run
2. Writes it to `sclaude-config` volume at `/sclaude-config/.credentials.json`
3. Sets `CLAUDE_CONFIG_DIR=/sclaude-config` so Claude Code reads credentials from there
4. Credentials persist in the Docker volume across container restarts

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
- ✅ Cannot become root (non-root user, no-new-privileges)
- ✅ All capabilities dropped (except NET_BIND_SERVICE)
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
docker volume ls | grep sclaude

# Inspect a specific volume
docker volume inspect sclaude-config

# Remove specific volume
docker volume rm sclaude-apt

# Remove all sclaude volumes
docker volume rm sclaude-config sclaude-rootfs sclaude-npm sclaude-pip sclaude-apt
```
