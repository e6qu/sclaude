# Example: Claude Code via sclaude in a Dev Container

Run Claude Code in a sandboxed Docker container managed by sclaude, all inside a dev container.

## Usage

1. Copy the `.devcontainer/` folder into your project root.
2. Set `ANTHROPIC_API_KEY` in your environment (or use OAuth).
3. Open in VS Code and choose "Reopen in Container", or use the CLI:

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . sclaude
```

The first run builds the sclaude sandbox image (takes a few minutes).

## Authentication

**API key** (simplest): Set `ANTHROPIC_API_KEY` on your host. It's forwarded into the outer dev container, then into the sclaude sandbox.

**OAuth**: Run `claude` on the host first to cache credentials in `~/.claude/.credentials.json`. sclaude syncs them into the sandbox automatically.

## What's included

- Docker-in-Docker (for sclaude's nested containers)
- sclaude CLI (installed from latest release)

## Why sclaude over plain Claude Code?

sclaude wraps Claude Code in a Docker sandbox with:
- Filesystem isolation (only workspace accessible)
- Resource limits (CPU, memory, PIDs)
- All Linux capabilities dropped
- No privilege escalation

See the [security docs](https://github.com/e6qu/sclaude/blob/main/docs/security.md) for details.
