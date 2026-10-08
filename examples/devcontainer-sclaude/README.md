# Claude Code through sclaude in a devcontainer

This example installs the released sclaude wrapper in an Ubuntu 24.04
devcontainer with Docker-in-Docker. That Docker daemon creates sclaude's
sandbox; Docker commands inside the sandbox use its own rootless Podman.

## Use

Copy this example's [.devcontainer](.devcontainer/) directory into your
project root. Set `ANTHROPIC_API_KEY` on the host before starting it, or
sign in through sclaude.

Open the project in VS Code and choose Reopen in Container, or run:

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . sclaude
```

The first sclaude session builds its sandbox image. The wrapper applies
its mounts, resource limits and capability restrictions within the outer
devcontainer; see [security](../../docs/security.md).

## Authentication and persistence

The API key is forwarded into the devcontainer, then into the sandbox.
For OAuth, run `sclaude` and follow its sign-in link on the host.

This example does not mount the host's Claude credentials or transcripts.
To sclaude, the host is the outer devcontainer, so signing in on your macOS
or Linux host alone does not make its credentials available there.
Sandbox credentials, caches and home data live in volumes managed by the
Docker-in-Docker daemon. Back them up before discarding that engine's data.

Edit [.devcontainer/devcontainer.json](.devcontainer/devcontainer.json) to
change the outer container. Use `sclaude config` for sandbox settings;
[host state](../../docs/host-state.md) explains any sharing you enable.
