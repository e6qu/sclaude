# Contributing

## Setup

```bash
git clone https://github.com/e6qu/sclaude.git
cd sclaude
./sclaude install
pre-commit install --install-hooks
```

`install` links both wrappers into `~/.local/bin`. `pre-commit` comes from
`brew install pre-commit` or `pipx install pre-commit`. If you once set
`core.hooksPath=.githooks`, unset it first: `git config --unset core.hooksPath`.

You need Docker or Podman, bash, and shellcheck.

## Before you push

- `pre-commit run --all-files` passes. It runs shellcheck, actionlint,
  `bash -n` and `zsh -n` on the scripts, and the commit message check. CI
  runs the same hooks on Linux and macOS.
- `bash test_e2e.sh` passes. The suite runs on its own `-e2e` volumes and
  leaves your sandbox state alone. [Testing](docs/e2e-testing.md) covers
  the matrix, engines, and running part of the suite.
- `sclaude` and `scodex` stay identical apart from the tool constants at
  the top. Test T24 fails when a shared function diverges.
- Docs change in the same PR as the code. Delete what is no longer true.

Shell rules: `#!/usr/bin/env bash`, `printf` rather than `echo -e`, `[ ]`
rather than `[[ ]]` unless you need pattern matching, `$(command)` rather
than backticks, every variable quoted, `portable_sha256` rather than
`shasum` or `sha256sum`. Both wrappers must run on macOS and Linux.

## Fixing a bug

1. Add a test to `test_e2e.sh` that fails.
2. Fix it in both wrappers.
3. Run the suite and the hooks.
4. Commit as `fix: ...` and add a row to `BUGS.md`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), checked by a
hook. The type decides the next version: `fix:` bumps the patch, `feat:` the
minor, a `!` after the type or a `BREAKING CHANGE:` footer the major.
`docs:`, `test:`, `ci:` and `chore:` do not release.

```
feat: add --network-none flag for offline mode
fix: credential sync fails when python3 is missing on the host
```

## Releases

Merging to `main` opens or updates a release PR. Merging that PR publishes
the release: wrappers attached to a GitHub release, images pushed to
`ghcr.io`. [Releasing](docs/releasing.md) has the details, including what
to do when a release stops part way.

## Workflow policy

`pull_request_target` is not allowed in `.github/workflows/`. It runs with
the base repository's secrets on code a pull request supplies. A pre-commit
hook rejects it. Use `pull_request` for untrusted contexts and
`push: branches: [main]` for trusted ones.

## Layout

| Path | What it is |
|---|---|
| `sclaude`, `scodex` | The two wrappers |
| `test_e2e.sh`, `test_lib.sh` | The test suite and its harness |
| `test_devcontainers.sh` | Dev container build and smoke tests (`npm install -g @devcontainers/cli` first) |
| `cleanup.sh` | macOS helper for reclaiming disk and engine state |
| `.devcontainer/` | Dev container for working on sclaude |
| `examples/` | Dev containers that use Claude Code directly, or through sclaude |
| `.github/workflows/` | CI and release automation |
| `.githooks/`, `.pre-commit-config.yaml` | The hooks CI and `git commit` run |
| `release-please-config.json`, `.release-please-manifest.json` | Release automation |
| `docs/` | [Host state](docs/host-state.md), [image](docs/image.md), [storage layout](docs/storage-layout.md), [security](docs/security.md), [testing](docs/e2e-testing.md), [releasing](docs/releasing.md) |
| `BUGS.md`, `CHANGELOG.md` | Bug history; release history, written by release-please |
