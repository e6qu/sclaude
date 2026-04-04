# Contributing to sclaude

## Setup

```bash
git clone https://github.com/e6qu/sclaude.git
cd sclaude
chmod +x sclaude test_e2e.sh
```

Requirements: Docker (or Podman), bash, shellcheck.

## Development

The entire project is a single bash script (`sclaude`). Edit it directly.

After any change, the version hash updates automatically and the image rebuilds on next run.

## Code Standards

- Must pass `shellcheck sclaude` with zero warnings
- Must pass `zsh -n sclaude` (zsh syntax compatibility)
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

All 16 tests must pass. Tests cover:
- Basic commands (version, build, cleanup, reset, update)
- TTY/non-TTY detection
- Credential sync (macOS Keychain / Linux file)
- Volume permissions and persistence
- Resource limits (PID containment)
- Path handling (spaces, colons)
- Portability (zsh invocation, shebang, printf)

### Testing on Linux from macOS

Use Lima to spin up a Linux VM:

```bash
brew install lima
limactl create --name=sclaude-linux --vm-type=vz --mount-writable template://docker
limactl start sclaude-linux
lima sclaude-linux bash ~/projects/sclaude/test_e2e.sh
```

See [docs/e2e-testing.md](docs/e2e-testing.md) for full details.

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
2. When the release PR merges, creates a GitHub release with the `sclaude` script attached

## Adding a Bug Fix

1. Reproduce the issue
2. Add a test case to `test_e2e.sh` that fails
3. Fix the bug in `sclaude`
4. Verify all tests pass: `bash test_e2e.sh`
5. Verify shellcheck: `shellcheck sclaude test_e2e.sh`
6. Commit with `fix: <description>`
7. Update `BUGS.md` if applicable

## Project Structure

```
sclaude              # Main script (the whole project)
test_e2e.sh          # E2E test suite
README.md            # Quick start and usage
CONTRIBUTING.md      # This file
BUGS.md              # Bug tracker and fix history
CHANGELOG.md         # Release history (managed by release-please)
LICENSE              # MIT
.github/workflows/   # CI + release-please automation
docs/
  security.md        # Threat model and security analysis
  storage-layout.md  # Docker volume architecture
  e2e-testing.md     # Test plan and VM setup
```
