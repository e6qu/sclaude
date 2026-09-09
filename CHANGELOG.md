# Changelog

## [2.15.1](https://github.com/e6qu/sclaude/compare/v2.15.0...v2.15.1) (2026-09-09)


### Bug Fixes

* let a half-published release be finished ([#62](https://github.com/e6qu/sclaude/issues/62)) ([b42ecb7](https://github.com/e6qu/sclaude/commit/b42ecb7b7424149a8537530290cce7888827ce10))

## [2.15.0](https://github.com/e6qu/sclaude/compare/v2.14.4...v2.15.0) (2026-09-09)


### Features

* ~/.local/share gets its own volume, so uv tools survive ([#60](https://github.com/e6qu/sclaude/issues/60)) ([df249db](https://github.com/e6qu/sclaude/commit/df249dbd63f61ed96618c82df07caa2761811467))

## [2.14.4](https://github.com/e6qu/sclaude/compare/v2.14.3...v2.14.4) (2026-09-09)


### Bug Fixes

* carry over the identity git actually uses in the workspace ([#56](https://github.com/e6qu/sclaude/issues/56)) ([efc8c45](https://github.com/e6qu/sclaude/commit/efc8c456452e2ada640d90bff0461ae4c625dc36))

## [2.14.3](https://github.com/e6qu/sclaude/compare/v2.14.2...v2.14.3) (2026-09-09)


### Bug Fixes

* publish smoke test reads the image labels, not the metadata file ([#55](https://github.com/e6qu/sclaude/issues/55)) ([193d6a4](https://github.com/e6qu/sclaude/commit/193d6a45c1b1bfc540795d1c07ce8ca45f18086f))

## [2.14.2](https://github.com/e6qu/sclaude/compare/v2.14.1...v2.14.2) (2026-09-09)


### Performance Improvements

* rebuild one layer for a CLI release, and stop rebuilding what is cached ([#53](https://github.com/e6qu/sclaude/issues/53)) ([c8d9ebc](https://github.com/e6qu/sclaude/commit/c8d9ebce962d881cc9d595239eaab7d1e0112d90))

## [2.14.1](https://github.com/e6qu/sclaude/compare/v2.14.0...v2.14.1) (2026-09-08)


### Bug Fixes

* no tar warnings from the host state sync ([#51](https://github.com/e6qu/sclaude/issues/51)) ([012a5b4](https://github.com/e6qu/sclaude/commit/012a5b4ad8e5fe7c78455025b584ee83c7db0d60))

## [2.14.0](https://github.com/e6qu/sclaude/compare/v2.13.0...v2.14.0) (2026-09-07)


### Features

* host clipboard bridge, both ways, text and images ([#48](https://github.com/e6qu/sclaude/issues/48)) ([e8e65fd](https://github.com/e6qu/sclaude/commit/e8e65fd4f1307295fa0e0667b9928067b4c2d4d5))

## [2.13.0](https://github.com/e6qu/sclaude/compare/v2.12.0...v2.13.0) (2026-09-07)


### Features

* publish the sandbox image per architecture with a multi-arch manifest ([#46](https://github.com/e6qu/sclaude/issues/46)) ([bbaac8b](https://github.com/e6qu/sclaude/commit/bbaac8be6323cf5cb1c486ad43dac05bf8523881))

## [2.12.0](https://github.com/e6qu/sclaude/compare/v2.11.0...v2.12.0) (2026-09-07)


### Features

* SAGENT_GIT_PROTOCOL, ssh by default when the host gh uses it ([#44](https://github.com/e6qu/sclaude/issues/44)) ([b7a0a68](https://github.com/e6qu/sclaude/commit/b7a0a68ab2494ba0669895f225cdb96c52018bed))

## [2.11.0](https://github.com/e6qu/sclaude/compare/v2.10.0...v2.11.0) (2026-09-07)


### Features

* host clipboard, terminal identity, git config and gh login inside the sandbox ([#42](https://github.com/e6qu/sclaude/issues/42)) ([bf8949a](https://github.com/e6qu/sclaude/commit/bf8949a5ddb56e42eb63ee535632737d10dd7045))

## [2.10.0](https://github.com/e6qu/sclaude/compare/v2.9.0...v2.10.0) (2026-09-06)


### Features

* working sign-in from inside the sandbox, shell command, everyday utilities ([#40](https://github.com/e6qu/sclaude/issues/40)) ([94c46f3](https://github.com/e6qu/sclaude/commit/94c46f36dd0ec252d6fe7958a0ee531acf9f08ed))

## [2.9.0](https://github.com/e6qu/sclaude/compare/v2.8.0...v2.9.0) (2026-09-06)


### Features

* detect TLS interception before every build and take the CA from the host trust store ([#38](https://github.com/e6qu/sclaude/issues/38)) ([d46e9ac](https://github.com/e6qu/sclaude/commit/d46e9ac62b0cd6b85582682a53faefea25177d0a))

## [2.8.0](https://github.com/e6qu/sclaude/compare/v2.7.0...v2.8.0) (2026-09-06)


### Features

* `status` snapshot and `doctor` diagnostics commands ([#36](https://github.com/e6qu/sclaude/issues/36)) ([c848ca7](https://github.com/e6qu/sclaude/commit/c848ca749c0ef40b377048fd560f60cdae0eff59))

## [2.7.0](https://github.com/e6qu/sclaude/compare/v2.6.4...v2.7.0) (2026-09-05)


### Features

* CA bundle for TLS-inspecting proxies, Rancher Desktop guidance, symlink-safe workspace mounts ([#32](https://github.com/e6qu/sclaude/issues/32)) ([5793fb5](https://github.com/e6qu/sclaude/commit/5793fb5037e2f6308d1a5078d607c922cec19b2b))
* configurable toolchains with latest defaults, JS/Java tooling, self-clearing caches, disk usage report ([#34](https://github.com/e6qu/sclaude/issues/34)) ([485620b](https://github.com/e6qu/sclaude/commit/485620b52f66aa09d96edfd0cb95699fbcd8e4af))

## [2.6.4](https://github.com/e6qu/sclaude/compare/v2.6.3...v2.6.4) (2026-09-04)


### Bug Fixes

* build release assets from the tag, not the triggering commit ([#30](https://github.com/e6qu/sclaude/issues/30)) ([dae7747](https://github.com/e6qu/sclaude/commit/dae7747a98ab63cb5180ba8c95cb3926e5cead0b))

## [2.6.3](https://github.com/e6qu/sclaude/compare/v2.6.2...v2.6.3) (2026-09-04)


### Bug Fixes

* clamp nested podman log noise; prune stale CONTRIBUTING test list ([#26](https://github.com/e6qu/sclaude/issues/26)) ([902ac99](https://github.com/e6qu/sclaude/commit/902ac99882e1dd85f18815b35399fec4d576e401))

## [2.6.2](https://github.com/e6qu/sclaude/compare/v2.6.1...v2.6.2) (2026-09-04)


### Bug Fixes

* /tmp workspaces shadowed by tmpfs; refuse / as workspace ([#24](https://github.com/e6qu/sclaude/issues/24)) ([375d81e](https://github.com/e6qu/sclaude/commit/375d81e99ddc2a0cd456c676aba49d7e51c514cd))

## [2.6.1](https://github.com/e6qu/sclaude/compare/v2.6.0...v2.6.1) (2026-09-04)


### Bug Fixes

* reset leaves pinned volumes silently; boy-scout doc and test hardening ([#21](https://github.com/e6qu/sclaude/issues/21)) ([63cac3b](https://github.com/e6qu/sclaude/commit/63cac3bdc59cf7a45fc2ca5081099ad2c1665fb1))

## [2.6.0](https://github.com/e6qu/sclaude/compare/v2.5.3...v2.6.0) (2026-09-03)


### Features

* nested containers by default, engine flavor autodetection, config file, browser-open shim ([#18](https://github.com/e6qu/sclaude/issues/18)) ([55ebd08](https://github.com/e6qu/sclaude/commit/55ebd08de2f9b94d92f9666f0ddd9fabeb4a7382))

## [2.5.3](https://github.com/e6qu/sclaude/compare/v2.5.2...v2.5.3) (2026-09-03)


### Bug Fixes

* T10 CI validity after releases; idempotent release workflow with asset verification ([#16](https://github.com/e6qu/sclaude/issues/16)) ([368179a](https://github.com/e6qu/sclaude/commit/368179a194957c821ff376cb7728f84dc3546c64))

## [2.5.2](https://github.com/e6qu/sclaude/compare/v2.5.1...v2.5.2) (2026-09-03)


### Bug Fixes

* corrupted release-check cache crash; expand CI and local test coverage ([#14](https://github.com/e6qu/sclaude/issues/14)) ([e3da91f](https://github.com/e6qu/sclaude/commit/e3da91f6da8b922a4b3eef4ad893a0ab6d44f2d9))

## [2.5.1](https://github.com/e6qu/sclaude/compare/v2.5.0...v2.5.1) (2026-09-03)


### Bug Fixes

* image loading, pip, UID-1000 sudo, and SELinux support across docker/podman ([#12](https://github.com/e6qu/sclaude/issues/12)) ([f18cfe4](https://github.com/e6qu/sclaude/commit/f18cfe4a1fcac90dddb1471cdb369aa66617b603))

## [2.5.0](https://github.com/e6qu/sclaude/compare/v2.4.0...v2.5.0) (2026-05-21)


### Features

* idempotent update, --force-rebuild flag, wrapper version display, deeper smoke tests ([#10](https://github.com/e6qu/sclaude/issues/10)) ([feb212c](https://github.com/e6qu/sclaude/commit/feb212cb6685140f9e717fb0574cb05af581c5bc))

## [2.4.0](https://github.com/e6qu/sclaude/compare/v2.3.0...v2.4.0) (2026-05-21)


### Features

* self-update wrappers on update + pre-commit and CI from prior PR ([#8](https://github.com/e6qu/sclaude/issues/8)) ([b94b17a](https://github.com/e6qu/sclaude/commit/b94b17afeacf67dec52f66e7f4906bb3b39ebfd6))

## [2.3.0](https://github.com/e6qu/sclaude/compare/v2.2.0...v2.3.0) (2026-05-21)


### Features

* add Codex sandbox wrapper, engine selection, and pre-commit hooks ([#6](https://github.com/e6qu/sclaude/issues/6)) ([3afc723](https://github.com/e6qu/sclaude/commit/3afc7234e92585070d13cb58a58c5a9059b68953))

## [2.2.0](https://github.com/e6qu/sclaude/compare/v2.1.0...v2.2.0) (2026-04-04)


### Features

* add devcontainers, gh CLI, fix bugs [#26](https://github.com/e6qu/sclaude/issues/26)-32 ([#4](https://github.com/e6qu/sclaude/issues/4)) ([e754f07](https://github.com/e6qu/sclaude/commit/e754f0770cfd2c76b84d2e6d634df5c2f9549363))

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
