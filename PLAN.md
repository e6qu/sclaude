# Plan: Codex CLI Support

Status: implemented in the current worktree.

## Goal

Support running OpenAI Codex CLI in the same Docker isolation model that `sclaude`
currently uses for Claude Code, while preserving existing `sclaude` behavior and
adding a separate physical `scodex` script.

Final user-facing shape:

- Keep `sclaude` as the Claude-compatible physical script.
- Add `scodex` as a separate physical script for Codex.
- Use one shared Docker image and common sandbox implementation for both scripts.
- Keep tool-specific config/auth volumes separate.
- Maintain compatibility with bash and zsh invocation patterns.
- Keep both scripts clean under ShellCheck.
- Check whether a newer wrapper release is available and guide users through
  installing the new `sclaude`/`scodex` scripts.

## Codex Facts Verified

- Official Codex CLI install path is `npm i -g @openai/codex`.
- Official upgrade path is `npm i -g @openai/codex@latest`.
- Local CLI checked on this machine: `codex-cli 0.132.0`.
- Codex has interactive mode (`codex [PROMPT]`) and non-interactive mode
  (`codex exec [PROMPT]`).
- Codex uses `CODEX_HOME` for file-backed config/auth. File-backed auth lives at
  `$CODEX_HOME/auth.json`; docs state this file contains access tokens and must be
  treated like a password.
- In a Docker/container boundary, Codex docs allow `--sandbox danger-full-access`
  or `--dangerously-bypass-approvals-and-sandbox` when Docker is the intended
  sandbox. If the inner Linux sandbox is left enabled, it may fail in Docker when
  namespace, setuid `bwrap`, or seccomp operations are blocked.

References:

- https://developers.openai.com/codex/cli
- https://developers.openai.com/codex/cli/reference
- https://developers.openai.com/codex/noninteractive
- https://developers.openai.com/codex/auth
- https://developers.openai.com/codex/agent-approvals-security

## Review Findings

### High: `sudo apt` is intended but currently broken in the sandbox

`sclaude` installs sudo and grants the `claude` user passwordless access to
`apt`, `apt-get`, and `dpkg` (`sclaude:74`). The runtime container also uses
`--security-opt=no-new-privileges` (`sclaude:316`), which prevents setuid sudo
from gaining root. Agent CLIs may need to install system packages while working,
so the package-install path should be supported deliberately instead of being a
half-working convenience.

Plan: keep an allowlisted passwordless sudo path for `apt`, `apt-get`, and
`dpkg`, then adjust runtime security options and capabilities only as much as
needed for that path to work. Document that this permits root inside the
container for package management, while the host boundary still depends on Docker
isolation, no Docker socket mount, workspace-only bind mounts, resource limits,
and network assumptions.

### High: management commands build the image before they run

The script builds the image at `sclaude:155` before dispatching commands like
`update`, `cleanup`, `version`, `volumes`, and `reset` (`sclaude:161-218`).
Consequences:

- `sclaude reset` can build an image before deleting volumes.
- `sclaude volumes` can build an image even though it only lists volumes.
- `sclaude cleanup` can create the current image before removing old ones.
- `sclaude update` can perform an initial cached build and then a no-cache build.
- The "Container image not built yet" branch in `version` is effectively
  unreachable after the eager build.

Fix: parse and dispatch management commands before `ensure_image`.

### High: host GID handling is fragile

The Dockerfile uses `groupadd -f -g ${USER_GID} claude` then `useradd ... -g
claude` (`sclaude:71-72`). On hosts where the numeric GID already exists in the
Ubuntu base image, `groupadd -f` can avoid failure while not guaranteeing that
the `claude` group has the host GID. macOS `staff` GID `20` is a common case.

Fix: resolve the group by numeric GID with `getent group "$USER_GID"`; if it
exists, use that group name for `useradd`. Otherwise create a new group with the
requested GID. Verify with a build test for a colliding GID.

### Medium: the apt volume is misleading

`sclaude-apt` is created and mounted at `/var/cache/apt` (`sclaude:241`,
`sclaude:310`), but the helper container does not manage its permissions
(`sclaude:262-285`), `apt` would run as root if it worked, and `/var/lib/apt/lists`
is not persisted. Combined with the broken sudo path, the volume currently gives
users a persistence promise that is not real.

Fix: redesign package installation as an explicit supported feature. Either
persist the correct apt cache/list directories with matching permissions, or
remove the apt volume and document package installs as runtime-ephemeral while
leaving npm/pip caches persistent.

### Medium: security docs overstate Docker network isolation

The docs say bridge networking prevents access to host-only services
(`docs/security.md:164-184`). Docker bridge networking does isolate container
`localhost`, but host services may still be reachable through Docker gateway
addresses or Docker Desktop host aliases depending on platform. The docs should
state the real boundary and call out outbound exfiltration clearly.

### Medium: credentials are persisted into Docker volumes

Claude credentials are copied from host storage into `sclaude-config`
(`sclaude:247-285`). That is necessary for convenience, but the docs should state
that the volume contains secrets. Codex support will add the same concern for
`auth.json`, which official docs describe as password-equivalent.

### Low: wrapper flags are only parsed after management dispatch

`--yolo` and `--no-yolo` are stripped only after management commands
(`sclaude:220-235`). Commands such as `sclaude --no-yolo version` are treated as a
Claude invocation instead of a wrapper command. A proper wrapper parser should
handle wrapper flags before command dispatch and leave tool flags untouched.

## Codex Support Design

### 1. Split wrapper parsing from tool arguments

Add a small parser for wrapper-owned flags:

- `--tool claude|codex`
- `--yolo`
- `--no-yolo`
- management commands: `build`, `update`, `cleanup`, `version`, `volumes`, `reset`

Everything else must remain in the tool argument array without interpretation.
This matters because flags collide: Claude uses `-p` for print mode, while Codex
uses `-p` for profile.

Each physical script should set the tool directly:

1. `sclaude` sets `TOOL=claude`.
2. `scodex` sets `TOOL=codex`.
3. An internal `--tool claude|codex` override can exist only for tests, if useful.

### 2. Generalize image and metadata

Rename internals from Claude-specific names to agent/tool-neutral names where
possible:

- `TOOL=claude|codex`
- `TOOL_BIN=claude|codex`
- `IMAGE_NAME=sagent-sandbox:$VERSION_HASH` or another single shared image name.
- Metadata should include wrapper hash, tool name, installed CLI versions, build
  timestamp, UID, and GID.

Install both CLIs in one shared image:

```dockerfile
RUN npm install -g @anthropic-ai/claude-code @openai/codex
```

Do not split images by tool. If image size or update time becomes a problem
later, address it inside the single shared image design.

### 3. Add tool-specific config volumes

Keep credentials separate by tool:

- Claude: `sclaude-config` mounted at `/sclaude-config`; set
  `CLAUDE_CONFIG_DIR=/sclaude-config`.
- Codex: `scodex-config` mounted at `/scodex-config`; set
  `CODEX_HOME=/scodex-config`.

Shared volumes can remain shared only if they are tool-neutral:

- home/rootfs: share a neutral rootfs volume such as `sagent-rootfs`, unless
  tool state collisions appear in testing.
- npm/pip caches can be shared if ownership is correct, but separate volumes are
  easier to reason about for reset and cleanup.

### 4. Implement Codex auth sync

Support these auth paths:

- Preferred automation path: pass through `CODEX_API_KEY`, `OPENAI_API_KEY`, and
  `CODEX_ACCESS_TOKEN` when set.
- File-backed login cache: copy host `${CODEX_HOME:-$HOME/.codex}/auth.json` into
  the `scodex-config` volume as `/scodex-config/auth.json` after JSON validation.
- Config sync: copy `config.toml`, `instructions.md`, and `AGENTS.md` from
  `${CODEX_HOME:-$HOME/.codex}` into `scodex-config` when present.

Set permissions on copied Codex auth/config files to the runtime UID/GID.

### 5. Map yolo semantics per tool

Claude yolo:

```bash
claude --dangerously-skip-permissions ...
```

Codex yolo:

```bash
codex --dangerously-bypass-approvals-and-sandbox ...
```

or:

```bash
codex --sandbox danger-full-access --ask-for-approval never ...
```

Use the first form for closest parity with current `sclaude` behavior. Document
that `--no-yolo` may leave Codex's inner Linux sandbox enabled, which can fail
inside Docker unless the container is configured for `bwrap`/seccomp.

### 6. Do not translate common short flags

Avoid a generic `-p` alias for Codex. It means different things:

- Claude: print/headless mode.
- Codex: profile selection.

For Codex headless use, require explicit Codex syntax:

```bash
scodex exec "summarize this repo"
```

Optionally add a wrapper-only long alias later:

```bash
scodex --print "summarize this repo"
```

where the wrapper expands to `codex exec`.

### 7. Runtime command construction

Build the final command from a provider function:

- `claude`: command is `claude "${TOOL_ARGS[@]}"`.
- `codex`: command is `codex "${TOOL_ARGS[@]}"`.

Common Docker runtime options remain shared:

- workspace mount
- memory, CPU, PID, tmpfs, no-new-privileges
- capability drop
- TTY detection
- env pass-through

Add Codex-specific env:

- `CODEX_HOME=/scodex-config`
- `CODEX_API_KEY=${CODEX_API_KEY:-}`
- `OPENAI_API_KEY=${OPENAI_API_KEY:-}`
- `CODEX_ACCESS_TOKEN=${CODEX_ACCESS_TOKEN:-}`
- `CODEX_CA_CERTIFICATE=${CODEX_CA_CERTIFICATE:-}`

### 8. Update docs and examples

Required docs changes:

- README usage for `scodex`.
- Storage layout for `scodex-config` and Codex auth.
- Security doc corrections for sudo, apt, network, and credential exfiltration.
- Devcontainer example for Codex through the Docker sandbox.
- Uninstall/reset instructions for both tool volume sets.

### 9. Add wrapper release checks

Both physical scripts should check whether a newer project release is available
without blocking normal CLI use.

Implementation constraints:

- Use the GitHub releases API or release redirect with a short timeout.
- Treat network failures as non-fatal and quiet unless the user explicitly runs a
  wrapper update/check command.
- Cache the last check timestamp in a Docker volume or a small local state file
  so every invocation does not hit the network.
- Show concrete install/update commands when a newer release exists.
- Upload both `sclaude` and `scodex` as release assets so existing `sclaude`
  users can update their installed script and then install `scodex`.

## Test Plan

### Static checks

- `shellcheck sclaude scodex test_e2e.sh test_devcontainers.sh`
- `bash -n sclaude`
- `bash -n scodex`
- `zsh -n sclaude`
- `zsh -n scodex`

### Existing Claude regression tests

- Existing `test_e2e.sh` must keep passing for `sclaude`.
- Add a test proving management commands no longer trigger image builds when the
  command does not need an image.

### Codex smoke tests

- Build image with Codex installed.
- `scodex --version` or `scodex version` reports wrapper metadata and
  `codex --version`.
- `scodex exec --help` works without auth.
- `echo "hi" | scodex exec - --help` or equivalent no-TTY path does not pass `-t`.
- `scodex --no-yolo --version` leaves yolo flags out of the Codex command.
- Default `scodex` includes the Codex yolo flag.

### Wrapper release-check tests

- A network failure does not fail normal `sclaude` or `scodex` execution.
- A mocked newer release prints install/update guidance.
- The release check is cached and not repeated on every invocation.

### Codex auth tests

- With a fake host `auth.json`, helper sync writes valid JSON to
  `scodex-config:/auth.json` with runtime UID/GID ownership.
- Malformed `auth.json` is skipped with a warning.
- Env passthrough works for `CODEX_API_KEY`, `OPENAI_API_KEY`, and
  `CODEX_ACCESS_TOKEN`.

### Sandbox tests

- Confirm the container cannot read files outside the mounted workspace.
- Confirm PID and memory limits still apply.
- Confirm `sudo apt-get update` and a small package install work inside the
  container.
- Confirm supported package installs do not expose the Docker socket or host
  filesystem outside the mounted workspace.
- Confirm the Docker socket is not mounted.

## Suggested Implementation Order

1. Fix command dispatch so management commands run before image creation.
2. Make the supported sudo/apt path actually work and update tests/docs
   accordingly.
3. Fix UID/GID group resolution in the Dockerfile.
4. Add provider parsing and command construction while keeping Claude behavior
   unchanged.
5. Install Codex CLI in the image and expose `scodex`.
6. Add `scodex-config`, Codex env passthrough, and auth sync.
7. Keep both scripts bash/zsh-compatible and ShellCheck-clean as implementation
   constraints, not after-the-fact cleanup.
8. Add Codex-specific tests.
9. Add release-check/update guidance for both physical scripts.
10. Update README, security docs, storage docs, and devcontainer examples.
