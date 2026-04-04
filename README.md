# sclaude - Sandboxed Claude Code

Run [Claude Code](https://claude.ai/code) in a secure Docker sandbox. Same CLI, isolated filesystem.

## Requirements

- Docker (or Podman)
- macOS or Linux
- bash (zsh also works)

## Install

```bash
# From latest release
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o sclaude
chmod +x sclaude
sudo mv sclaude /usr/local/bin/sclaude

# Or from source
git clone https://github.com/e6qu/sclaude.git
cd sclaude
chmod +x sclaude
sudo ln -s "$(pwd)/sclaude" /usr/local/bin/sclaude
```

## Update

```bash
sclaude update                 # Update Claude CLI inside the container

# Update sclaude itself (from source)
git pull && sclaude --build

# Or re-download latest release
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o /usr/local/bin/sclaude
chmod +x /usr/local/bin/sclaude
```

## Usage

```bash
sclaude                      # Interactive mode (yolo by default)
sclaude "fix the bug"        # Direct prompt
sclaude --resume             # Resume last session
sclaude -p "query"           # Print mode (headless/CI, no TTY needed)
sclaude --no-yolo            # Disable default yolo mode
```

Yolo mode (`--dangerously-skip-permissions`) is on by default since you're already sandboxed. Pass `--no-yolo` to disable.

All `claude` flags work: `--resume`, `-p`, `--output-format`, `--verbose`, etc. OAuth credentials auto-sync from the host (macOS Keychain or `~/.claude/.credentials.json` on Linux).

## Commands

| Command | Description |
|---------|-------------|
| `sclaude update` | Rebuild with latest Claude CLI |
| `sclaude cleanup` | Remove old image versions |
| `sclaude version` | Show version and build metadata |
| `sclaude volumes` | Show Docker volume info |
| `sclaude reset` | Delete all persistent data |

## How It Works

```
sclaude [args]  -->  Docker container  -->  claude [args]
                     - Workspace mounted at $(pwd)
                     - Non-root user (your UID/GID)
                     - 4GB RAM / 2 CPUs / 100 PIDs
                     - All capabilities dropped
                     - Credentials from Docker volume
```

Workspace is the only host directory accessible. Everything else is isolated.

## Persistence

Data survives across runs via Docker volumes:

| Volume | Contents |
|--------|----------|
| `sclaude-config` | Credentials, config |
| `sclaude-rootfs` | Home directory, preferences |
| `sclaude-npm` | npm global packages |
| `sclaude-pip` | pip user packages |
| `sclaude-apt` | apt package cache |

## Configuration

Edit the top of the `sclaude` script:

```bash
MEMORY_LIMIT="8g"    # Default: 4g
CPU_LIMIT="4"        # Default: 2
PIDS_LIMIT="200"     # Default: 100
```

## Best Practice

```bash
git commit -am "before sclaude"   # Save state
sclaude "fix all bugs"            # Run (yolo by default)
git diff                          # Review
git commit                        # or: git reset --hard
```

## Uninstall

```bash
sclaude cleanup                        # Remove old image versions
sclaude reset                          # Remove volumes
docker images sclaude-sandbox -q | xargs -r docker rmi # Remove all images
sudo rm /usr/local/bin/sclaude         # Remove script
```

## Dev Containers

Use the dev container for sclaude development, or copy an example into your own project:

| Config | Purpose |
|--------|---------|
| [`.devcontainer/`](.devcontainer/) | Develop sclaude itself (Docker-in-Docker, shellcheck, zsh) |
| [`examples/devcontainer-claude/`](examples/devcontainer-claude/) | Use Claude Code directly in any project |
| [`examples/devcontainer-sclaude/`](examples/devcontainer-sclaude/) | Use Claude Code via sclaude (sandboxed) in any project |

```bash
# Test all devcontainers locally
npm install -g @devcontainers/cli
bash test_devcontainers.sh
```

## Docs

- [Security Architecture](docs/security.md) - Threat model, attack scenarios, hardening
- [Storage Layout](docs/storage-layout.md) - Volume architecture and credential sync
- [E2E Testing](docs/e2e-testing.md) - Cross-platform test plan and Lima VM setup
- [Bug Tracker](BUGS.md) - Known issues and fix history
- [Changelog](CHANGELOG.md) - Release history
- [Contributing](CONTRIBUTING.md)

## License

MIT
