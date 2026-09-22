# Testing

`test_e2e.sh` tests the wrappers on macOS and Linux with Docker or Podman.
`test_devcontainers.sh` builds and smoke-tests the dev containers.

## Prerequisites

- Docker or Podman installed and running
- bash
- zsh, for the zsh compatibility test; skipped when absent
- `npm install -g @devcontainers/cli` for `test_devcontainers.sh`

## Test matrix

| Test | What it validates | Bugs covered |
|---|---|---|
| T01: `version` command | Basic execution, hashing (`shasum` vs `sha256sum`) | #13 |
| T02: Image build | Dockerfile generation, UID/GID mapping | #1, #4, #35 |
| T03: Piped input (no TTY) | `version` runs with stdin piped | #6 |
| T04: `--yolo` flags | `version` accepts `--yolo` and `--no-yolo` in both wrappers | -- |
| T04b: `--docker` flags | `--docker`/`--no-docker`/`SAGENT_DOCKER` parse | -- |
| T05: Credential sync keeps the newer copy | Linux: the host copy lands in the volume, a newer sandbox copy survives the next run, a newer host copy replaces it. macOS: a run completes and the config volume exists; the keychain is left alone | #12, #14, #16, #102 |
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
| T32c: Refreshed CA bundle re-staged | A stub engine fails TLS once so the wrapper takes the CA from the host trust store; the build context then carries the refreshed bundle | -- |
| T32d: Build guidance survives a broken engine | With every container after the TLS probe failing, a failed build still prints the whole guidance instead of stopping at its first line | -- |
| T33: VM share check | Stub engine reporting the `rancher-desktop` and `colima` contexts: a workspace outside `$HOME` is refused, `SAGENT_SKIP_SHARE_CHECK=1` and a `$HOME` workspace pass; other contexts are not checked | #74 |
| T34: docker CLI on rootless daemon | Stub engine reporting a rootless podman server: the run is refused after the engine probe, before any build, volume or run call | #75 |
| T35: Toolchain settings | Invalid versions rejected up front; each setting changes the image hash; config file applies and the environment wins | -- |
| T36: Toolchain stamps | A pip volume stamped for another Python is cleared with a warning on the next run; an unchanged toolchain leaves it alone | #76 |
| T37: `reset-caches` | Cache volumes removed; credentials, config and home volumes kept | -- |
| T37b: Share volume, migrated from the pip volume | `~/.local/share` has its own volume; content an older wrapper left in the pip volume's `share/` moves into it on the next run, so `uv tool install` survives a Python change | #84 |
| T38b: Config quoting and tools groups | A value holding `$` and a backtick is stored literally (a real file with that name proves it is not expanded), and `tools enable all` drops the Java tools instead of failing when there is no JDK; the cloud and infra groups select and deselect as one, an unknown group is an error, and listing the tools into a pipe that closes early is not an error | -- |
| T38: `tools` / `config` commands | Enable/disable rewrite `SAGENT_TOOLS` and change the hash; `config set/get/list/unset/path` with validation and unknown-key rejection; environment precedence reported; Java tools without a JDK | -- |
| T39: `status` | Every snapshot line present with the real engine and image; still prints, naming the problem, without an engine | -- |
| T40: `doctor` | Healthy setup: engine, workspace, limits, build-time TLS, image, CLIs, sandbox TLS, nested devices and cache stamps PASS, exit 0; missing engine and a rootless docker CLI stub produce FAIL lines and exit 1 | -- |
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
| T56: CPU limit above the docker daemon's CPUs refused | A stub docker server with 2 CPUs: `CPU_LIMIT=4` is refused before the engine is called, naming `config set CPU_LIMIT 2`, and `doctor` reports FAIL `limits`; `CPU_LIMIT=2` passes, and a podman server is not refused | #114 |
| T57: Extra mounts at their own paths, read-only by default | `SAGENT_EXTRA_MOUNTS` entries mount read-only, or read-write with `:rw`; spaces and a trailing slash are dropped; `status` lists them; a relative path, a missing directory, `/`, a colon, the workspace, the drop folder and a repeated entry are refused; in a real run the read-only folder refuses writes and the read-write one takes them | -- |

Bug numbers in the matrix refer to entries in [`BUGS.md`](../BUGS.md).

## Running the tests

The suite uses volumes with the `-e2e` suffix, so your sandbox volumes are
left alone. It shares the engine's image store with your normal runs, and
some tests write under your home directory and clean up after themselves.
A full run builds the shared image, rebuilds it once without cache (T10),
and builds a second image with a throwaway CA bundle (T31), which it
removes afterwards.

Run the suite from the repository root:

```bash
bash test_e2e.sh
```

To select Podman:

```bash
SAGENT_CONTAINER_ENGINE=podman bash test_e2e.sh
```

Test bodies run under `bash -ec`, so a failing command ends the test,
within bash's `errexit` rules (#72). Check an expected failure with an
`if`. Use `|| true` when the result does not matter.

Fixtures that get bind-mounted into containers are created under
`SAGENT_TEST_TMPDIR` (default `/tmp`). Point it under your home directory for
engines that share only `$HOME` with their VM, such as Rancher Desktop. Tests
that replicate `run_tool`'s mounts pass `$SAGENT_TEST_USERNS`, which the
suite sets to the wrapper's keep-id mapping on rootless podman.

Each test body has a timeout of 600 seconds, so an engine hang fails that
test and the suite goes on. Set `TEST_TIMEOUT_SECONDS=1200` on a slow
builder. Engine recovery and suite setup run outside that timeout.

### Testing Linux from a macOS host

A Linux VM needs the checkout and a supported engine. For rootless Podman
in the Podman machine VM, an SELinux-enforcing Fedora CoreOS, replace the
machine name and the path:

```bash
podman machine ssh --username core podman-machine-default \
    'SAGENT_CONTAINER_ENGINE=podman bash /path/to/sclaude/test_e2e.sh'
```

To run the suite in this repository's dev container, a UID-1000 Ubuntu
with Docker inside:

```bash
npm install -g @devcontainers/cli
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash /workspaces/sclaude/test_e2e.sh
```

### CI

CI runs the suite on pushes to `main` and on same-repository PRs, except
the release PR. The lint jobs and the PR title check run on every other PR,
fork PRs included.
[`ci.yml`](../.github/workflows/ci.yml) has the job conditions.

| Job | Environment |
|---|---|
| what-ran | Runs on every event, so the release PR, where every other job skips itself, still has a job to conclude on (#89) |
| test-linux | docker CLI on docker server (Ubuntu, AppArmor enforcing) |
| test-linux-podman | rootless podman CLI on podman (exercises the keep-id user mapping, #75) |
| test-linux-docker-cli-podman | real docker CLI on a rootful podman docker-compat socket (a rootless socket is refused by the wrapper, see #75/T34) |
| test-linux-podman-shim | podman fronted as the `docker` command |
| build-macos-image | Builds the trimmed image for the macOS jobs on Linux and publishes it as an artifact (#98) |
| test-macos (1/2, 2/2) | macOS host, docker CLI to dockerd in a colima Linux VM, two slices on two runners (#96) |
| test-macos-rancher (1/2, 2/2) | macOS host, Rancher Desktop's docker CLI (`~/.rd/bin`) to dockerd in its Lima VM, started headlessly with `rdctl`; the same slices as test-macos |
| test-devcontainers | UID-1000 docker-in-docker dev container, building the dev containers and then running the whole suite inside |

The macOS jobs run on Intel runners, because the Apple Silicon runners lack
nested virtualization. Building the image there would take most of the
job, so build-macos-image builds it once on Linux, trimmed to
`SAGENT_TOOLS=none` with no Go, Rust or Java, for the macOS runners' uid
and gid. Each macOS job loads that image and checks it is the one the
wrapper there computes. Those jobs skip T02, T10, T10b and T31, whose full
image builds do not depend on the engine and run in the Linux jobs, and
T12b, because colima shares only `$HOME` and `/tmp/colima` with its VM and
Rancher Desktop only `$HOME`.

T27 runs a container inside the sandbox through nested podman.

## Running part of the suite

`SAGENT_TEST_SKIP="T02 T10"` skips the named tests, reported as SKIP.

`SAGENT_TEST_SHARD="1/2"` runs every second test starting from the first,
and `"2/2"` the others. Tests are numbered in file order, skipped or not,
so the slices agree on which test is which and together cover each test
once. A test in `SAGENT_TEST_SKIP` stays skipped in its slice. CI runs
each macOS engine as two slices on two runners.

On failure the harness prints the last 30 lines of the test's output.
`FAIL_OUTPUT_LINES` changes that. Test bodies run with `-x`, so the tail
usually names the command that failed, even when that command sent its
own output elsewhere.

The trace covers the test's own shell only. The wrappers and scripts it
runs are untraced, so their captured stderr is clean. Capturing the stderr
of a group, subshell or shell function inside the test, as in
`$( { cmd; } 2>&1 )`, `$( (cmd) 2>&1 )` or `$(fn 2>&1)`, picks up trace
lines, because the trace follows file descriptor 2 into the capture. Do
not assert on those captures. Capture an external command instead. The
bash 3.2 that macOS ships lacks `BASH_XTRACEFD`, which would send the trace
elsewhere.

