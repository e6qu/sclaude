# sclaude - Sandboxed Claude Code

Run Claude Code in a secure Docker sandbox with persistent credentials and configuration.

## Quick Start

```bash
# Make executable and add to PATH
chmod +x sclaude
sudo ln -s "$(pwd)/sclaude" /usr/local/bin/sclaude

# Use it (OAuth credentials auto-synced from native claude)
sclaude                      # Interactive mode
sclaude --resume             # Resume session
sclaude --yolo               # YOLO mode (no permission prompts)
sclaude "your prompt"        # Direct prompt
```

## Commands

```bash
sclaude update          # Update to latest Claude CLI
sclaude cleanup         # Remove old image versions
sclaude version         # Show version and build metadata
sclaude volumes         # Show Docker volume information
sclaude reset           # Delete all persistent data
```

## What It Does

`sclaude` = `claude` + Docker sandbox + persistence

**Features**:
- ✅ Full TTY support (colors, interactive mode, keyboard shortcuts)
- ✅ All claude flags work (--resume, --verbose, etc.)
- ✅ Isolated to current directory only
- ✅ Resource limits (4GB RAM, 2 CPUs, 100 PIDs)
- ✅ Persistent credentials and configuration
- ✅ Auto-syncs OAuth from native claude (no re-login!)
- ✅ Package caches persist (npm, pip, apt)
- ✅ Auto-versioning (rebuilds when script changes)

**Security**:
- ❌ Cannot access files outside current directory
- ❌ Cannot modify host system
- ❌ Cannot escape Docker container
- ❌ Cannot become root

## Persistence

Uses Docker volumes for all persistent data:

| Volume | Purpose |
|--------|---------|
| `sclaude-config` | Credentials and configuration |
| `sclaude-rootfs` | Home directory (theme, preferences) |
| `sclaude-npm` | npm global packages |
| `sclaude-pip` | pip user packages |
| `sclaude-apt` | apt package cache |

**What persists**:
- OAuth credentials (auto-synced from macOS Keychain)
- Theme and UI preferences
- npm/pip packages
- apt package cache (faster reinstalls)

**What's ephemeral** (by design):
- apt packages (installed to system directories)
- Container filesystem (reset on each run via --rm flag)

## Usage

### Interactive Mode

```bash
sclaude
```

Full terminal support:
- ANSI colors and formatting
- Interactive prompts and menus
- All keyboard shortcuts (Shift+Enter, Ctrl+C, arrow keys)
- Multi-line input
- Command history

### YOLO Mode

```bash
sclaude --yolo "fix all bugs"
```

Alias for `--dangerously-skip-permissions`. Safe because sandboxed to current directory.

### Resume Sessions

```bash
sclaude --resume
```

Sessions work identically to `claude --resume`. Project directory mounted at same path ensures session compatibility.

### Package Management

Claude can install packages inside the sandbox:

```bash
sclaude "install figlet and use it"
```

**What works**:
- ✅ npm install (project dependencies)
- ✅ npm install -g (global packages, persisted)
- ✅ pip install --user (user packages, persisted)
- ✅ sudo apt-get install (temporary, reinstalls fast via cache)

## How It Works

```
sclaude [args]
    ↓
Docker Container
    • Volumes:
      - sclaude-config → credentials & config
      - sclaude-rootfs → home directory
      - sclaude-npm/pip/apt → package caches
      - $(pwd) → workspace
    • User: non-root (matches your UID/GID)
    • Limits: 4GB RAM, 2 CPUs, 100 processes
    • Network: internet access (for packages)
    • Security: capabilities dropped, no-new-privileges
    • Environment: CLAUDE_CONFIG_DIR=/sclaude-config
    ↓
claude [args]
    • Reads credentials from Docker volume
    • Full TTY/ANSI support
    • Can install packages
    • Cannot escape workspace directory
```

## First Run

First time, it builds the Docker image (3-5 minutes):

```bash
sclaude
# [sclaude] Building Docker image (version: 190c3793)...
# ... (downloads packages) ...
# [sclaude] Image built successfully
```

OAuth credentials automatically synced from macOS Keychain. No re-authentication needed!

## Version Management

**Auto-rebuild**: Script changes trigger automatic rebuild with new version hash:

```bash
# Edit sclaude
vim sclaude

# Next run auto-detects change and rebuilds
sclaude
# [sclaude] Script changed, rebuilding image...
```

**Cleanup old versions**:

```bash
sclaude cleanup
```

**View version info**:

```bash
sclaude version
# Script version: 190c3793
# Container metadata:
# {
#     "version": "190c3793",
#     "build_timestamp": "2025-10-27T07:14:48Z"
# }
```

## Volume Management

**View volumes**:

```bash
sclaude volumes
```

**Reset all data**:

```bash
sclaude reset
# WARNING: Deletes credentials, packages, preferences
```

**Manual management**:

```bash
docker volume ls | grep sclaude
docker volume inspect sclaude-config
docker volume rm sclaude-apt
```

## Security

See `security-notes.md` for full analysis.

**Summary**:
- Path traversal blocked (mount boundary enforced by kernel)
- Container escape prevented (no docker socket, capabilities dropped)
- Privilege escalation blocked (no-new-privileges, non-root)
- Resource exhaustion prevented (4GB RAM, 2 CPUs, 100 PIDs limits)
- Cannot access host files outside workspace

**Tested against**:
- `../../../etc/passwd` attacks
- Symlink escapes
- Fork bombs
- Memory exhaustion
- Privilege escalation attempts

## Configuration

Edit resource limits in `sclaude` script:

```bash
MEMORY_LIMIT="8g"    # Default: 4g
CPU_LIMIT="4"        # Default: 2
PIDS_LIMIT="200"     # Default: 100
```

## Best Practices

**Before running**:
```bash
git commit -am "before sclaude"
```

**After running**:
```bash
git diff          # Review changes
npm test          # Test functionality
git commit        # Accept
# OR
git reset --hard  # Reject
```

## Troubleshooting

**"the input device is not a TTY"**
- Only happens in non-interactive environments
- Use from a real terminal, not piped: `sclaude` not `echo "..." | sclaude`

**"Permission denied" on /sclaude-config**
- Script auto-fixes volume permissions on each run
- If issues persist, run: `sclaude reset`

**Image build fails**
- Check Docker is running: `docker ps`
- Check internet connection

**Claude doesn't start**
- Check native claude is logged in: `claude --version`
- OAuth will auto-sync from Keychain

## Uninstall

```bash
# Remove volumes and data
sclaude reset

# Remove images
docker rmi sclaude-sandbox

# Remove script
sudo rm /usr/local/bin/sclaude
```

## Comparison

| Feature | `claude` | `sclaude` |
|---------|----------|-----------|
| Usage | `claude [args]` | `sclaude [args]` |
| Filesystem | Full system | Current dir only |
| Safety | OS permissions | Docker isolation |
| Credentials | Keychain (macOS) | Docker volume |
| Persistence | Host ~/.claude | Docker volumes |
| TTY/Colors | ✅ | ✅ |
| --resume | ✅ | ✅ |
| --yolo | --dangerously-skip-permissions | --yolo alias |
| Resource limits | None | 4GB/2CPU/100PID |

## License

MIT

## Credits

Built on [Claude Code](https://claude.ai/code) by Anthropic.
