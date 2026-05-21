# sclaude / scodex - Sandboxed Agent CLIs

Run [Claude Code](https://claude.ai/code) or OpenAI Codex CLI in a Docker sandbox.
Same CLI, isolated filesystem.

## Requirements

- Docker or Podman
- macOS or Linux
- bash (zsh also works)

## Install

```bash
# From latest release
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o sclaude
chmod +x sclaude
sudo mv sclaude /usr/local/bin/sclaude
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/scodex -o scodex
chmod +x scodex
sudo mv scodex /usr/local/bin/scodex

# Or from source
git clone https://github.com/e6qu/sclaude.git
cd sclaude
chmod +x sclaude scodex
sudo ln -s "$(pwd)/sclaude" /usr/local/bin/sclaude
sudo ln -s "$(pwd)/scodex" /usr/local/bin/scodex
```

## Update

```bash
sclaude update                 # Self-update both wrappers and rebuild the shared image with latest CLIs
scodex update                  # Same — self-updates wrappers and rebuilds the shared image
sclaude check-update           # Check (don't install) whether newer wrapper scripts are available

# Update sclaude itself (from source)
git pull && sclaude --build

# Or re-download latest release manually
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/sclaude -o /usr/local/bin/sclaude
chmod +x /usr/local/bin/sclaude
curl -fsSL https://github.com/e6qu/sclaude/releases/latest/download/scodex -o /usr/local/bin/scodex
chmod +x /usr/local/bin/scodex
```

## Usage

```bash
sclaude                      # Interactive mode (yolo by default)
sclaude "fix the bug"        # Direct prompt
sclaude --resume             # Resume last session
sclaude -p "query"           # Print mode (headless/CI, no TTY needed)
sclaude --no-yolo            # Disable default yolo mode

scodex                       # Interactive Codex mode
scodex "fix the bug"         # Direct prompt
scodex exec "query"          # Non-interactive Codex mode
scodex --no-yolo             # Disable Docker-boundary yolo mode
```

Yolo mode is on by default since Docker is the outer sandbox. `sclaude` maps it
to `--dangerously-skip-permissions`; `scodex` maps it to
`--dangerously-bypass-approvals-and-sandbox`. Pass `--no-yolo` to disable.

All native CLI flags are passed through unchanged. Note that `-p` means Claude
print mode for `sclaude`, but Codex profile selection for `scodex`; use native
Codex syntax such as `scodex exec "query"` for non-interactive Codex runs.

Claude OAuth credentials auto-sync from the host (macOS Keychain or
`~/.claude/.credentials.json` on Linux). Codex auth auto-syncs
`${CODEX_HOME:-$HOME/.codex}/auth.json`; API key environment variables are also
passed through.

## Commands

| Command | Description |
|---------|-------------|
| `sclaude update` / `scodex update` | Self-update both wrapper scripts to the latest release, then rebuild the shared image with the latest Claude and Codex CLIs (use `SAGENT_SKIP_SELF_UPDATE=1` to skip the wrapper download) |
| `sclaude check-update` / `scodex check-update` | Check whether newer wrapper scripts are available without installing them |
| `sclaude cleanup` | Remove old image versions |
| `sclaude version` | Show version and build metadata |
| `sclaude volumes` | Show Docker volume info |
| `sclaude reset` | Delete all persistent data |

## How It Works

```
sclaude [args]  -->  Docker container  -->  claude [args]
scodex [args]   -->  Docker container  -->  codex [args]
                     - Workspace mounted at $(pwd)
                     - Non-root user (your UID/GID)
                     - Shared image with both CLIs
                     - 4GB RAM / 2 CPUs / 100 PIDs
                     - Limited capabilities for sudo apt package installs
                     - Credentials from tool-specific Docker volumes
```

Workspace is the only host directory accessible. Everything else is isolated.

## Persistence

Data survives across runs via Docker volumes:

| Volume | Contents |
|--------|----------|
| `sclaude-config` | Claude credentials, config |
| `scodex-config` | Codex auth and config |
| `sagent-rootfs` | Shared home directory, preferences |
| `sagent-npm` | Shared npm global packages |
| `sagent-pip` | Shared pip user packages |
| `sagent-apt-cache` | Shared apt package cache |
| `sagent-apt-lists` | Shared apt package lists |

## Configuration

Edit the top of the `sclaude` script:

```bash
MEMORY_LIMIT="8g"    # Default: 4g
CPU_LIMIT="4"        # Default: 2
PIDS_LIMIT="200"     # Default: 100
```

Container engine selection:

```bash
SAGENT_CONTAINER_ENGINE=docker sclaude version
SAGENT_CONTAINER_ENGINE=podman scodex version
```

If `SAGENT_CONTAINER_ENGINE` is unset, the scripts try `docker` first and then
`podman`. Engine health checks are bounded; tune with
`SAGENT_ENGINE_TIMEOUT_SECONDS`.

## Best Practice

```bash
git commit -am "before sclaude"   # Save state
sclaude "fix all bugs"            # Run (yolo by default)
git diff                          # Review
git commit                        # or: git reset --hard
```

## Uninstall

```bash
sclaude cleanup                        # Remove old shared image versions
sclaude reset                          # Remove volumes
docker images sagent-sandbox -q | xargs -r docker rmi # Remove all images
sudo rm /usr/local/bin/sclaude /usr/local/bin/scodex
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
