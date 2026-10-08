# Claude Code directly in a devcontainer

This example runs Claude Code in an Ubuntu 24.04 devcontainer with Node.js
LTS and Python 3.12. It does not use sclaude or create nested containers.

## Use

Copy this example's [.devcontainer](.devcontainer/) directory into your
project root. Set `ANTHROPIC_API_KEY` in the host environment before
starting the devcontainer, or sign in inside it.

Open the project in VS Code and choose Reopen in Container, or use the
Dev Container CLI:

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . claude
```

The configuration installs the Claude Code npm package and VS Code
extension. Claude runs with the devcontainer user's access to the workspace
and any other configured mounts; sclaude's sandbox limits do not apply.

## Authentication and persistence

`remoteEnv` forwards `ANTHROPIC_API_KEY` from the host. For OAuth, run
`claude` inside and open its sign-in link on the host.

Credentials are stored in the devcontainer user's home. This example does
not configure a persistent home volume or mount the host's Claude state.
Do not rely on its credentials surviving container replacement; sign in
again or add an appropriate persistent mount.

Edit [.devcontainer/devcontainer.json](.devcontainer/devcontainer.json) to
change tools, extensions or mounts.
