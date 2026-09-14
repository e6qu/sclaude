# Contributing to sclaude

## Setup

```bash
git clone https://github.com/e6qu/sclaude.git
cd sclaude
./sclaude install
```

`install` links both wrappers into `~/.local/bin`.

Requirements: Docker (or Podman), bash, shellcheck.

### Pre-commit hooks

This repo uses [pre-commit](https://pre-commit.com) to enforce shell linting,
GitHub Actions linting, Conventional Commit messages, AI-attribution stripping,
and a hard block on `pull_request_target` triggers in workflows (see
[Forbidden workflow triggers](#forbidden-workflow-triggers) below). Install
once:

Install pre-commit itself (`brew install pre-commit` on macOS,
`pipx install pre-commit` anywhere), then the hooks:

```bash
pre-commit install --install-hooks
```

If you once set `core.hooksPath=.githooks`, unset it first so pre-commit can
manage the hooks directory: `git config --unset core.hooksPath`.

After install, `git commit` runs the configured pre-commit and commit-msg
hooks automatically. Run them on demand with `pre-commit run --all-files`.
CI runs the same `pre-commit run --all-files` on Linux and macOS, so the local
hooks and CI linting cannot drift apart.

### Forbidden workflow triggers

GitHub Actions' `pull_request_target` trigger is **prohibited** in this repo.
It runs in the base-repo context with secrets available, but PRs can supply
arbitrary refs and scripts — a well-known exfiltration footgun. Use
`pull_request` for untrusted contexts (no secrets) and `push: branches: [main]`
for trusted post-merge coverage. The `forbid-pull-request-target` pre-commit
hook fails any commit that introduces the token under `.github/workflows/`.
Do not work around it.

## Development

The project ships two physical bash scripts: `sclaude` for Claude Code and
`scodex` for Codex CLI. They intentionally share the same Docker image design.

The image hash covers the generated Dockerfile (including the toolchain
versions interpolated into its `FROM`/`ARG` lines and the tool selection), the
UID/GID build args and the optional CA bundle: any change to the Dockerfile
heredoc, a version default or the tool registry yields a new hash and the
image rebuilds on the next run. Changes elsewhere in the wrappers (runtime
flags, commands, messages) keep the hash, so existing users are not forced to
rebuild. Version defaults live in the `*_VERSION` constants near the top of
the wrappers; the optional tooling is the `SAGENT_TOOL_REGISTRY` table (name,
group, description) plus one install fragment per tool (`get_dockerfile_content`
for the npm and Java tools, `emit_extra_tools` for the infra and cloud ones)
and one presence check per tool in T19. Volume stamps take their values from
the settings automatically.

## Code Standards

- Must pass `shellcheck sclaude scodex` with zero warnings
- Must pass `zsh -n sclaude` and `zsh -n scodex` (zsh syntax compatibility)
- Must work on both macOS and Linux
- Shebang: `#!/usr/bin/env bash`
- Use `printf` instead of `echo -e`
- Use `[ ]` tests, not `[[ ]]` where possible (exception: pattern matching)
- Use `$(command)` not backticks
- Quote all variables: `"$VAR"` not `$VAR`
- Use `portable_sha256` instead of `shasum` or `sha256sum` directly

## Testing

Run the E2E test suite:

```bash
bash test_e2e.sh
```

The suite runs on its own `-e2e` volumes (`SAGENT_VOLUME_SUFFIX`), so a
local run leaves your sandbox state alone.

All tests must pass. The test matrix in
[docs/e2e-testing.md](docs/e2e-testing.md) documents what each test covers.

See [docs/e2e-testing.md](docs/e2e-testing.md) for the full test matrix,
Podman runs, and testing Linux from a macOS host.

## Commits

This project uses [Conventional Commits](https://www.conventionalcommits.org/) and [release-please](https://github.com/googleapis/release-please) for automated releases.

Commit messages must follow this format:

```
<type>: <description>

[optional body]
```

Types:
- `feat:` — new feature (bumps minor version)
- `fix:` — bug fix (bumps patch version)
- `docs:` — documentation only
- `test:` — adding or updating tests
- `chore:` — maintenance, CI, tooling
- `feat!:` or `fix!:` or `BREAKING CHANGE:` — breaking change (bumps major version)

Examples:

```bash
git commit -m "feat: add --network-none flag for offline mode"
git commit -m "fix: credential sync fails when python3 missing on host"
git commit -m "docs: update security notes for new capabilities"
```

When a PR with conventional commits merges to `main`, release-please automatically:
1. Opens a release PR with updated CHANGELOG.md and version bump
2. When the release PR merges, creates a GitHub release with the `sclaude` and `scodex` scripts attached, then builds and publishes the per-architecture images and their manifest

### The release PR's checks sit waiting

The release PR is opened by `github-actions[bot]`, and GitHub holds workflow
runs from bot-authored pull requests until someone approves them. Nothing
runs until you press **Approve and run** on the PR's checks — including the
one job that is meant to run there, `what-ran`, which states that the test
jobs are skipped on purpose. Left unapproved, the run eventually goes red
and the PR looks broken when it is not.

One click per release. If that gets old, giving release-please a personal
access token instead of `GITHUB_TOKEN` makes the PR come from a human
account and its checks start on their own; loosening the approval policy
repo-wide would also do it, at the cost of letting fork pull requests run
without review.

### When a release does not finish

A release is created as a draft, on a tag the workflow pushes first, and
published only once both wrappers are attached and verified, so `latest`
never points at a release without them. The next release PR is built after
that, from the published tag; while a release is stuck as a draft there is
no release PR, and none should be merged until the draft is published.

A failure after the release exists leaves a draft, or a published release
with no images. Run the workflow by hand with the tag to publish what is
missing (it publishes the draft too); that path skips release-please itself
and runs the publishing jobs only, so it is safe to repeat:

```bash
gh workflow run release-please.yml -f tag=v2.15.1
```

A failure before the release exists is the other case: once anything else
lands on `main` after the release commit, and it touches a workflow file,
GitHub lets no Actions token tag or release that commit (#107). The job
says so. Finish it with your own credentials, with the version from
`.release-please-manifest.json` and the merged release PR's commit:

```bash
git push origin <sha>:refs/tags/v3.0.0
awk '/^## \[3\.0\.0\]/{f=1; next} f&&/^## \[/{exit} f' CHANGELOG.md > notes.md
gh release create v3.0.0 --draft --title v3.0.0 --notes-file notes.md
gh pr edit <release PR> --remove-label "autorelease: pending" --add-label "autorelease: tagged"
gh workflow run release-please.yml -f tag=v3.0.0
```

The label swap matters: with `autorelease: pending` still on the PR, every
later run retries that same version instead of moving on. The next push to
`main` then builds the release PR for what came after.

## Adding a Bug Fix

1. Reproduce the issue
2. Add a test case to `test_e2e.sh` that fails
3. Fix the bug in `sclaude`
4. Verify all tests pass: `bash test_e2e.sh`
5. Verify linting: `pre-commit run --all-files` (shellcheck, actionlint, zsh/bash syntax)
6. Commit with `fix: <description>`
7. Update `BUGS.md` if applicable

## Dev Containers

Test all devcontainer configs:

```bash
npm install -g @devcontainers/cli
bash test_devcontainers.sh
```

This verifies that all three configs (sclaude-dev, claude-code example, sclaude example) build and pass smoke tests. These tests also run in CI.

## Project Structure

| Path | What it is |
|---|---|
| `sclaude`, `scodex` | The two wrappers; identical apart from tool constants (T24 checks) |
| `test_e2e.sh` | E2E test suite |
| `test_lib.sh` | Test harness: timeouts, tracing, skip and slice knobs, results |
| `test_devcontainers.sh` | Dev container build and smoke tests |
| `cleanup.sh` | macOS-only helper for reclaiming disk and Docker/Podman state |
| `.devcontainer/` | Dev container for working on sclaude |
| `examples/devcontainer-claude/` | Claude Code directly in a dev container |
| `examples/devcontainer-sclaude/` | Claude Code via sclaude in a dev container |
| `README.md`, `CONTRIBUTING.md`, `BUGS.md`, `CHANGELOG.md`, `LICENSE` | Usage, this file, bug history, release history (release-please), MIT |
| `.github/workflows/` | CI and release automation |
| `.githooks/` | The commit-msg hook that strips AI attribution |
| `.pre-commit-config.yaml` | Lint hooks; CI runs the same set |
| `release-please-config.json`, `.release-please-manifest.json` | Release automation |
| `renovate.json` | Dependency updates for the pre-commit hooks |
| `docs/security.md` | Threat model and security analysis |
| `docs/storage-layout.md` | Volumes, synced files, environment |
| `docs/e2e-testing.md` | Test matrix, CI jobs, running part of the suite |
