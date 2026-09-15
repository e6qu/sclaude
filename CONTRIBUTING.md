# Contributing

## Setup

You need Docker or Podman, bash, zsh and pre-commit. pre-commit comes from
`brew install pre-commit` or `pipx install pre-commit`, and installs
shellcheck and actionlint itself. If this checkout once set
`core.hooksPath=.githooks`, run `git config --unset core.hooksPath` first.

```bash
git clone https://github.com/e6qu/sclaude.git
cd sclaude
./sclaude install
pre-commit install --install-hooks
```

## Before you push

- `pre-commit run --all-files` passes. It runs shellcheck, actionlint,
  `bash -n` and `zsh -n` on the scripts, and the docs character check. The
  commit message check runs when you commit. CI runs the same hooks on
  Linux and macOS.
- `bash test_e2e.sh` passes. [Testing](docs/e2e-testing.md) covers the
  engines, the volumes the suite uses, and running part of it.
- `sclaude` and `scodex` stay identical apart from the tool constants at
  the top and three functions that differ per agent: `read_credentials`,
  `sync_state` and `run_tool`. Test T24 fails when anything else diverges.
- Docs change in the same PR as the code. Delete what is no longer true.
- Docs are plain ASCII, apart from accented letters in names. No em
  dashes, emoji, arrows or box-drawing. The `plain-docs` hook checks.
  Headings are sentence case. Describe what happens.

Both wrappers must run on macOS and Linux.

- `#!/usr/bin/env bash`.
- `printf` for formatted output. No `echo -e`.
- `[ ]` for tests. `[[ ]]` only where pattern matching needs it.
- `$(command)` for command substitution.
- Quote every expansion unless splitting is the point.
- `portable_sha256` for hashes.

## Fixing a bug

1. Add a test to `test_e2e.sh`, or to `test_devcontainers.sh` for the dev
   containers, that fails.
2. Fix it. Shared code changes go into both wrappers.
3. Run the suite and the hooks.
4. Commit as `fix: ...` and add a row to `BUGS.md`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/) for commit
messages and PR titles. A hook checks the message and CI checks the title.
`fix:` requests a patch release and `feat:` a minor one. A `!` after the
type, or a `BREAKING CHANGE:` footer, requests a major one. `docs:`,
`test:`, `ci:` and `chore:` request none.

```text
feat: mount a drop folder for files handed to the agent
fix: credential sync fails when python3 is missing on the host
```

## Releases

[Releasing](docs/releasing.md) covers the release PR, what it publishes,
and what to do when a release stops part way.

## Workflow policy

A pre-commit hook rejects `pull_request_target` in `.github/workflows/`.
That trigger runs with the base repository's secrets, and a workflow that
checks out the pull request's code hands them to that code. Use
`pull_request` for PR checks and `push: branches: [main]` for trusted jobs.

## Layout

| Path | What it is |
|---|---|
| `sclaude`, `scodex` | The two wrappers |
| `test_e2e.sh`, `test_lib.sh` | The test suite and its harness |
| `test_devcontainers.sh` | Dev container build and smoke tests |
| `cleanup.sh` | macOS helper for reclaiming disk and engine state |
| `.devcontainer/` | Dev container for working on sclaude |
| `examples/` | Dev containers that use Claude Code directly, or through sclaude |
| `.github/workflows/` | CI and release automation |
| `.githooks/`, `.pre-commit-config.yaml` | The hooks CI and `git commit` run |
| `release-please-config.json`, `.release-please-manifest.json` | Release automation |
| `docs/` | [Host state](docs/host-state.md), [image](docs/image.md), [storage layout](docs/storage-layout.md), [security](docs/security.md), [testing](docs/e2e-testing.md), [releasing](docs/releasing.md) |
| `BUGS.md`, `CHANGELOG.md` | Bug history; release history, written by release-please |

## What changes the image

The image hash covers the generated Dockerfile, the uid and gid build
arguments, and the CA bundle. A change to the Dockerfile text in the
wrappers, to a version default, or to a tool's install fragment gives a new
hash, and a user without that image builds it on the next run. Changes
elsewhere in the wrappers, such as flags, commands and messages, keep the
hash.

Version defaults are the `*_VERSION` constants near the top of the
wrappers. To add an optional tool:

1. Add its name, group and description to `SAGENT_TOOL_REGISTRY`.
2. Add its install fragment to `get_dockerfile_content` (npm and Java
   tools) or `emit_extra_tools` (infra and cloud tools).
3. Add a presence check, and an absence check when deselected, to T19.

Volume stamps take their values from the settings, so a new toolchain
version needs no stamp change.
