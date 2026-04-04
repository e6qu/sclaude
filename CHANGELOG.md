# Changelog

## [2.1.0](https://github.com/e6qu/sclaude/compare/v2.0.0...v2.1.0) (2026-04-04)


### Features

* add install/update instructions to GitHub release notes ([9bdcc65](https://github.com/e6qu/sclaude/commit/9bdcc6570c096715cfd81dd812c5630c340eb564))

## [2.0.0](https://github.com/e6qu/sclaude/compare/v1.0.0...v2.0.0) (2026-04-04)


### ⚠ BREAKING CHANGES

* harden sclaude for cross-platform use, add CI and release automation ([#1](https://github.com/e6qu/sclaude/issues/1))

### Features

* harden sclaude for cross-platform use, add CI and release automation ([#1](https://github.com/e6qu/sclaude/issues/1)) ([6385591](https://github.com/e6qu/sclaude/commit/6385591dcee4586fdb40d8db23cd528c1059b9b8))

## [1.0.0](https://github.com/e6qu/sclaude/releases/tag/v1.0.0) (2026-04-05)

### Features

* Docker sandbox for Claude Code with persistent credentials and config
* Auto-sync OAuth from macOS Keychain and Linux file-based credentials
* Default yolo mode (`--dangerously-skip-permissions`) since container is sandboxed
* `--no-yolo` flag to disable default yolo mode
* Interactive and headless/CLI modes with automatic TTY detection
* `--resume` support (sessions persist across container runs)
* Volume persistence for credentials, npm, pip, and apt caches
* Resource limits: 4GB RAM, 2 CPUs, 100 PIDs, 8192 file descriptors
* Security hardening: capabilities dropped, no-new-privileges, non-root user
* Auto-versioning: script changes trigger image rebuild
* Subcommands: `update`, `cleanup`, `version`, `volumes`, `reset`

### Cross-Platform

* macOS (Darwin) and Linux support
* bash and zsh compatible (`#!/usr/bin/env bash` + `${BASH_SOURCE[0]:-$0}`)
* Portable SHA-256 hashing (`sha256sum` / `shasum` fallback)
* `printf` instead of `echo -e` for portability

### Bug Fixes

* 26 bugs identified and fixed (see [BUGS.md](BUGS.md) for full list)
* Temp file cleanup via EXIT trap
* Conditional `chown` to avoid slow recursive permission fix on every run
* Single helper container for permissions + credential sync (was 3 containers)
* JSON credential validation inside container (host may lack python3)
* `groupadd -f` and `useradd -o` for robust Dockerfile user creation
* Workspace path colon validation (Docker `-v` delimiter conflict)
* `grep -v` pipeline failure when no old images exist during cleanup
