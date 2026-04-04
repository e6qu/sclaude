# Example: Claude Code in a Dev Container

Run Claude Code directly inside a dev container. No Docker nesting or sclaude required.

## Usage

1. Copy the `.devcontainer/` folder into your project root.
2. Set `ANTHROPIC_API_KEY` in your environment (or use OAuth — see below).
3. Open in VS Code and choose "Reopen in Container", or use the CLI:

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . claude
```

## Authentication

**API key** (simplest): Set `ANTHROPIC_API_KEY` on your host. It's forwarded into the container via `remoteEnv`.

**OAuth**: Run `claude` inside the container and follow the login flow. Credentials persist in the container's home directory volume.

## What's included

- Node.js (LTS) and Python 3.12
- Claude Code CLI (`@anthropic-ai/claude-code`)
- VS Code Claude Code extension

## Customization

Edit `.devcontainer/devcontainer.json` to add your project's language runtimes, tools, or extensions.
