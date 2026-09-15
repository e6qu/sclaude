# Testing

One test suite, `test_e2e.sh`, runs on macOS and Linux against Docker or
Podman.

## Prerequisites

- Docker or Podman installed and running
- bash
- zsh, for the zsh compatibility test; skipped when absent

## Test matrix

| Test | What it validates | Bugs covered |
|---|---|---|
| T01: `version` command | Basic execution, hashing (`shasum` vs `sha256sum`) | #13 |
| T02: Image build | Dockerfile generation, UID/GID mapping | #1, #4, #35 |
| T03: Piped input (no TTY) | Non-TTY detection, `-it` flag handling | #6 |
| T04: `--yolo` flag conversion | Flag rewriting | -- |
| T04b: `--docker` flags | `--docker`/`--no-docker`/`SAGENT_DOCKER` parse | -- |
| T05: Credential sync keeps the newer copy | Linux: the host copy lands in the volume, a newer sandbox copy survives the next run, a newer host copy replaces it. macOS: the keychain read runs | #12, #14, #16, #102 |
| T06: Volume creation & permissions | Shared user volumes writable by agent user | #22 |
| T07: Volume persistence | Data survives across container runs | -- |
| T08: Cleanup command | Old image removal | -- |
| T09: Reset command | Volume deletion (non-interactive) | #64 |
| T09b: Reset pinned volumes | `reset` fails loudly naming volumes held by running containers | #64 |
| T10: Update command | `--no-cache` rebuild | -- |
| T10b: CLI-only update | With a stubbed registry lookup the CLIs look outdated: `update` takes the cached path (no `--no-cache` banner), rebuilds the agent-CLI layer and leaves both CLIs working | -- |
| T11: Resource limits (PID) | Fork bomb containment | -- |
| T12: Path with spaces | Quoting correctness in mounts; the spaced path is actually mounted and read | #10, #73 |
| T12b: /tmp workspace | Workspace under /tmp not shadowed by the sandbox tmpfs; physical path mounted at the logical path; the agent can read and write it | #65, #71, #75 |
| T12c: / workspace refused | `/` as workspace rejected (would expose the host filesystem) | #66 |
| T13: `volumes` report | No literal `-e` in output; the disk usage report lists the image, every volume with a size, and the caches total | #15 |
| T14: Zsh invocation | `BASH_SOURCE` fallback | #17 |
| T15: Temp file cleanup on failure | A stub engine fails the build; the wrapper's private `$TMPDIR` is empty afterwards. No real build on any platform | #1, #73, #98 |
| T16: Shebang portability | Script runs via `env bash` | #18 |
| T17: scodex version command | Codex wrapper smoke test | #40 |
| T17b: scodex exec --help | Inner Codex CLI loads config without errors | -- |
| T17c: sclaude --help | Inner Claude CLI loads config without errors | -- |
| T18: sudo apt works in sandbox | Package installation support | #33, #36 |
| T18b: pip install --user works | PEP 668 override lands packages in `sagent-pip` | #51 |
| T19: Image contents | Claude, Codex and GitHub CLIs plus the configured Node, Python/pip/uv, Go, Rust (rustfmt, clippy), Java and podman/pasta at the versions the wrapper reports; every selected tool (the js, java, infra and cloud groups: TypeScript through shadcn, Maven through Spring Boot CLI, kubectl, Helm, Terraform, Terragrunt, the AWS, Azure and Google Cloud CLIs) present and every unselected one absent | #40 |
| T19b: Clipboard shims, git defaults, locale | Without the bridge, `pbcopy`/`xclip`/`wl-copy`/`xsel` emit OSC 52 and the read shims fail with a message; `/etc/gitconfig` has the gh credential helper and LFS filters and no URL rewrite; `LANG=C.UTF-8` | -- |
| T19c: Clipboard bridge round trip | Against a fake host clipboard, the sandbox shims read text, targets and a PNG, and copy text and a PNG back; an unsupported target is refused; an unanswered request fails within 10 s | #92, #93 |
| T19d: Clipboard bridge in a real run | A run mounts the spool, sets `WAYLAND_DISPLAY` and `DISPLAY`, brings the X clipboard up before the tool starts, and pastes and copies through the host; the spool is gone afterwards; with the bridge off none of it exists | #91 |
| T19e: Sessions shared both ways | A session the host has is readable inside, one the sandbox writes lands on the host owned by the user, a session recorded in the volume before sharing moves out to the host, and `SAGENT_SESSIONS=0` shares nothing | -- |
| T19f: `SAGENT_SESSIONS=all` shares file-history | The host store is readable inside, what the sandbox writes lands on the host owned by the user, rewind data recorded in the volume beforehand moves out, and the default shares none of it | -- |
| T20a: Host git config, gh login and SSH sync | Host global git config lands in the home volume minus host-only keys (signing, credential helpers, editor, host paths), multi-valued keys and the excludes file intact; gh tokens per host (env token masked); with `SAGENT_GIT_PROTOCOL=https` every host gets the SSH-to-HTTPS rewrite and no `~/.ssh` is synced; unset it follows the host gh (ssh): no rewrite, `~/.ssh` synced 700/600 by manifest, a sandbox-made key untouched, and removed again on the next https run; `~/.gitconfig` exists; synced git files mirror the host | -- |
| T20c: Workspace git identity | An identity only the repo provides (invisible to a global-config read) is carried into the sandbox, so commits there have an author | -- |
| T20b: Sync tar quiet on clock skew | The extraction command read out of the wrapper stays silent on a tarball dated in the future (a host clock ahead of the engine VM made GNU tar warn per file) | -- |
| T20: scodex config sync | `auth.json` and `config.toml` land in `scodex-config`; an `auth.json` with a later `last_refresh` in the volume survives, a newer host copy replaces it | #40, #102 |
| T21: Release check non-fatal | Wrapper update check caches and does not fail normal flow | -- |
| T22: Native args pass through | Tool args after native command are not wrapper-dispatched | #39, #41 |
| T23: Explicit engine selection | `SAGENT_CONTAINER_ENGINE` works for both wrappers | -- |
| T24: Wrapper parity | Shared functions and main dispatch identical between `sclaude` and `scodex` (drift guard) | -- |
| T25: Corrupted release cache | Non-numeric cache content does not break execution | #58 |
| T26: `--force-rebuild` validation | Flag rejected outside the `update` command | -- |
| T27: Nested containers | `--docker` mode: nested pull/run/build via rootless podman | -- |
| T28: Config file | Config sourced at startup; env vars take precedence | -- |
| T29: Browser-open shim | `xdg-open`/`$BROWSER` render clickable terminal hyperlinks; Claude Code's localhost-callback sign-in URL is rewritten to the manual-code redirect with a paste note, other URLs untouched | #78 |
| T30: Isolation assertions | No engine socket, no cross-tool secrets, no host-sibling leakage | -- |
| T31: `SAGENT_CA_BUNDLE` | Bundle validation, hash coverage, and a real build whose curl/Python/Node trust a certificate issued by a bundled CA | #68 |
| T32: Dockerfile generation | Stub engine: CA block emitted only with a bundle, one file per certificate in the context, build-failure guidance printed; FROM/ARG carry the toolchain versions, `none` omits a toolchain, `SAGENT_TOOLS` selects exactly the named tools | #68 |
| T32b: dockerfile command | Prints the build's Dockerfile: `FROM`, the version hash as a label (no metadata file layer), the agent CLI install last and behind `ARG AGENT_CLI_REFRESH`; `SAGENT_IMAGE_UID`/`GID` change the hash; identical from both wrappers | -- |
| T32c: Refreshed CA bundle re-staged | A stub engine fails TLS once so the wrapper takes the CA from the host trust store; the build context must then carry the refreshed bundle, not the stale one it was staged with | -- |
| T32d: Build guidance survives a broken engine | With every container after the TLS probe failing, a failed build still prints the whole guidance instead of stopping at its first line | -- |
| T33: VM share check | Stub engine reporting the `rancher-desktop` and `colima` contexts: a workspace outside `$HOME` is refused, `SAGENT_SKIP_SHARE_CHECK=1` and a `$HOME` workspace pass; other contexts are not checked | #74 |
| T34: docker CLI on rootless daemon | Stub engine reporting a rootless podman server: the run is refused before any engine call; `version` still works | #75 |
| T35: Toolchain settings | Invalid versions rejected up front; each setting changes the image hash; config file applies and the environment wins | -- |
| T36: Toolchain stamps | A pip volume stamped for another Python is cleared with a warning on the next run; an unchanged toolchain leaves it alone | #76 |
| T37: `reset-caches` | Cache volumes removed; credentials, config and home volumes kept | -- |
| T37b: Share volume, migrated from the pip volume | `~/.local/share` has its own volume; content an older wrapper left in the pip volume's `share/` moves into it on the next run, so `uv tool install` survives a Python change | #84 |
| T38b: Config quoting and tools groups | A value holding `$` and a backtick is stored literally (a real file with that name proves it is not expanded), and `tools enable all` drops the Java tools instead of failing when there is no JDK; the cloud and infra groups select and deselect as one, an unknown group is an error, and listing the tools into a pipe that closes early is not an error | -- |
| T38: `tools` / `config` commands | Enable/disable rewrite `SAGENT_TOOLS` and change the hash; `config set/get/list/unset/path` with validation and unknown-key rejection; environment precedence reported; Java tools without a JDK | -- |
| T39: `status` | Every snapshot line present with the real engine and image; still prints, naming the problem, without an engine | -- |
| T40: `doctor` | Healthy setup: engine, workspace, build-time TLS, image, CLIs, sandbox TLS, nested devices and cache stamps PASS, exit 0; missing engine and a rootless docker CLI stub produce FAIL lines and exit 1 | -- |
| T41: TLS interception auto-fix | Stub engine answers the pre-build probe TLS-FAIL until a bundle arrives: the wrapper exports the host trust store, verifies it, persists bundle and setting, builds with the CA block; a configured bundle lacking the CA stops before the build naming the issuer | #77 |
| T42: `scodex login` | Stub engine: `login` gets `--device-auth`; explicit modes, `status` and `--help` are left alone; the tool container carries the workspace label | #78 |
| T43: `shell` | Fresh sandbox shell sees the workspace and runs as `agent`; with a sandbox running for the workspace, `shell` attaches to that container | -- |
| T44: Install and migrate without sudo | `install` copies both wrappers into a user directory and adds it to the shell startup file once (a second run and an rc that already has it change nothing); `update` moves an install out of a directory the user cannot write and clears the old copies; a writable directory and a git checkout are left alone | -- |
| T45: Update lists the changes and their PRs | With a stubbed releases API and CHANGELOG, `update` prints each version newer than the installed one, its entries and their pull request URLs, and stops at the version already installed | -- |
| T46: Timeout helper reaps its own timer | After a command finishes, the harness's timer subshell and its `sleep` are both gone | -- |
| T47: Apt mirror rewrites the image sources | Unset, no mirror layer and the default archive; set, the layer appears, the image hash changes, a missing trailing slash is added, and the `sed` it emits rewrites every stanza of a real sources file (security and ports included); a non-URL is refused | -- |
| T48: A test is retried only when the engine went away | The dead-engine signature is recognised and a plain assertion failure is not; a test that fails that way once is retried and reported as a pass, saying RETRY; a real failure is reported once, unretried | -- |
| T49: Agent attribution is off by default | The image's policy file sets `attribution.commit` and `attribution.pr` empty; `SAGENT_AI_ATTRIBUTION=1` leaves it out and changes the hash; other values are refused | #103, #104 |
| T50: mcp subcommand runs without the yolo flag | With a stub engine, `mcp list` gets no yolo flag while a prompt and `codex exec` do; for real, a server added through the wrapper is listed on the next run and gone after `mcp remove` | #111 |
| T51: `scodex mcp add` persists under a host config.toml | A server added inside survives runs while the host `config.toml` is unchanged, and is replaced once that file changes | #99 |
| T52: Volume suffix keeps the suite off the real volumes | No test names a real volume; both wrappers mount only suffixed names; a suffix with a space is refused; `volumes` lists the suffixed names | #101 |
| T53: Drop dir mounted at its own path, unsafe values refused | `~/sagent-drop` is created and mounted by default; `SAGENT_DROP_DIR` names another; a relative path, a missing directory, `/` and the workspace are refused; a real run reads and writes a file there | -- |
| T54: X11 clipboard served from the host, both ways | In a real run, an X client (what arboard does) finds an owner, reads the host PNG and text, and its own copy reaches the host before the sandbox takes the selection back | -- |
| T55: Build downloads go to a file first | No build download is piped into `tar`, `sh`, `env`, `gpg`, `unzip` or `tee`; every `-o /tmp/...` download is removed in the same step | #113 |

Bug numbers in the matrix refer to entries in [`BUGS.md`](../BUGS.md).

## Running the tests

The suite runs on its own volumes, named with the `-e2e` suffix, so your
sandbox state is not touched. It builds the shared image, rebuilds it once
without cache (T10), and builds a second image with a throwaway CA bundle
(T31), which it removes afterwards.

From the repo root on macOS or Linux:

```bash
bash test_e2e.sh
```

Against Podman instead of Docker:

```bash
SAGENT_CONTAINER_ENGINE=podman bash test_e2e.sh
```

Test bodies run under `bash -ec`, so every command in a test is an assertion
(#72); guard commands that are allowed to fail with `|| true` or an `if`.

Fixtures that get bind-mounted into containers are created under
`SAGENT_TEST_TMPDIR` (default `/tmp`). Point it under your home directory for
engines that share only `$HOME` with their VM, such as Rancher Desktop. Tests
that replicate `run_tool`'s mounts pass `$SAGENT_TEST_USERNS`, which the
suite sets to the wrapper's keep-id mapping on rootless podman.

Each test has a portable timeout so engine hangs fail cleanly instead of
blocking the suite. Override with `TEST_TIMEOUT_SECONDS=1200` when testing on
a slow builder.

### Testing Linux from a macOS host

Any Linux VM with a container engine works. Rootless Podman inside the
Podman machine VM (SELinux-enforcing Fedora CoreOS):

```bash
podman machine ssh --username core podman-machine-default \
    'SAGENT_CONTAINER_ENGINE=podman bash /path/to/sclaude/test_e2e.sh'
```

Docker inside this repo's docker-in-docker dev container (UID-1000 Ubuntu):

```bash
npm install -g @devcontainers/cli
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash /workspaces/sclaude/test_e2e.sh
```

These two configurations exercise real platform differences: SELinux label
enforcement (bug #57) and the UID-1000 sudoers collision (bug #56).

### CI

For pushes to main and same-repo PRs, CI runs the suite across the full
engine matrix (see [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)):

| Job | Topology |
|---|---|
| what-ran | Runs on every event, including the release PR where every other job filters itself out, so the run always has a job to conclude on (#89) |
| test-linux | docker CLI on docker server (Ubuntu, AppArmor enforcing) |
| test-linux-podman | rootless podman CLI on podman (exercises the keep-id user mapping, #75) |
| test-linux-docker-cli-podman | real docker CLI on a rootful podman docker-compat socket (a rootless socket is refused by the wrapper, see #75/T34) |
| test-linux-podman-shim | podman fronted as the `docker` command |
| build-macos-image | Builds the trimmed image (`SAGENT_TOOLS=none`, no Go, Rust or Java) once on Linux for the macOS runners' uid/gid, and publishes it as an artifact (#98) |
| test-macos (1/2, 2/2) | macOS host, docker CLI to dockerd in a colima Linux VM (Intel runner; Apple Silicon runners lack nested virtualization). Two slices on two runners (#96). Loads the prebuilt image and checks it is the one the wrapper there computes. Skips T02, T10, T10b and T31, whose full image builds are engine-independent and covered by the Linux jobs, and T12b (colima shares only `$HOME` and `/tmp/colima`) |
| test-macos-rancher (1/2, 2/2) | macOS host, Rancher Desktop's docker CLI (`~/.rd/bin`) to dockerd in its Lima VM, started headlessly with `rdctl`; same slices, image and skips as test-macos (Rancher Desktop shares only `$HOME`) |
| test-devcontainers | UID-1000 docker-in-docker dev container, building the dev containers and then running the whole suite inside |

T27 adds one more nesting level inside each job (nested podman in the
sandbox), so the devcontainer and macOS jobs run three to four layers deep.

## Running part of the suite

`SAGENT_TEST_SKIP="T02 T10"` skips named tests, reported as SKIP.
`SAGENT_TEST_SHARD="1/2"` runs one slice: every second test starting from the
first. Tests are numbered in file order, skipped or not, so every slice
agrees on which test is which and together the slices run each test exactly
once. CI runs the macOS jobs as two slices on parallel runners.

A failing test prints the tail of its capture, and its shell runs traced, so
the last lines name the command that failed even when that command sent its
own output away. `FAIL_OUTPUT_LINES` sets how many lines are shown (30).

Only the test's own shell is traced; the wrappers and scripts it runs are
not, so capturing their stderr is safe. The one thing the trace does reach
is a group, subshell or shell function whose stderr is captured inside the
test, `$( { cmd; } 2>&1 )`, `$( (cmd) 2>&1 )`, `$(fn 2>&1)`, because the
trace follows file descriptor 2 into the capture. Do not assert on those;
capture an external command instead. (`BASH_XTRACEFD`, which would avoid
this, does not exist in the bash 3.2 that macOS ships.)

