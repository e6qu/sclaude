# Testing

[test_e2e.sh](../test_e2e.sh) runs the wrapper integration suite.
[test_devcontainers.sh](../test_devcontainers.sh) builds and smoke-tests
all three devcontainer configurations. The test scripts contain the
individual assertions; this guide covers selection, environments and
failure diagnosis.

## Prerequisites

Use Bash, Python 3 and a running Docker or Podman engine. Install zsh for
its compatibility check; that check skips when zsh is absent. Devcontainer
tests also need `npm install -g @devcontainers/cli`.

Run from the repository root:

```bash
bash test_e2e.sh
SAGENT_CONTAINER_ENGINE=podman bash test_e2e.sh
bash test_devcontainers.sh
```

Choose one engine per run. The integration suite uses `-e2e` volumes,
but shares the engine's image store with normal sessions. Some tests
create temporary files under your home directory. A full run builds the
sandbox, rebuilds without cache, and builds a temporary CA image; it can
take substantial time and disk space. Use focused regressions locally
and the CI matrix for full coverage.

## Coverage

| Area | Tests | Main checks |
|---|---|---|
| CLI and configuration | T01, T03-T04b, T14, T16-T17c, T21-T26, T28, T35, T38-T39, T42, T44-T45, T49-T51 | Argument forwarding, engine selection, wrapper parity, settings, installation and updates |
| Images and packages | T02, T10-T10b, T18-T19, T31-T32d, T41, T47, T55, T59 | Builds, tool selection, package installs, certificates, mirrors and download handling |
| Credentials and host state | T05, T19b-T20c, T29, T49-T51, T54 | Credential freshness, git/gh/SSH sync, sessions, clipboard and MCP persistence |
| Paths and storage | T06-T09b, T12-T13, T33, T36-T37b, T52-T53, T57, T65-T66 | Mount validation, persistence, cache stamps, resets and private nested storage slots |
| Isolation and processes | T11, T30, T34, T40, T56, T58, T67 | Resource ceilings, rootless mappings, engine recovery, Tini, signals and exit status |
| Nested applications | T27, T60, T62, T66, T68, T70-T72 | Docker API, Compose, BuildKit, PostgreSQL, Chromium, DNS and CI image integrity |
| Harness and diagnostics | T15, T43, T46, T48, T61, T63-T64, T69 | Cleanup, timeout handling, error capture, bounded recovery and shell lookup |

Ranges include lettered variants. Test IDs remain stable when assertions
change; see [test_e2e.sh](../test_e2e.sh) for exact coverage.

## Focused regressions

The following scripts can run with `bash SCRIPT` from the repository root
without a container engine. They exercise real wrapper functions or
workflow steps against controlled fixtures.

| Script | Integration test | Coverage |
|---|---|---|
| [test_engine_selection.sh](../test_engine_selection.sh) | T23 | Healthy, slow, missing and failing engines; bounded probes and no fallback |
| [test_buildkit.sh](../test_buildkit.sh) | T62 | BuildKit readiness, cold startup and stale sockets |
| [test_diagnostics.sh](../test_diagnostics.sh) | T63 | Full captures, crash headers, counters and shell stderr |
| [test_shell.sh](../test_shell.sh) | T64 | Container lookup and engine errors |
| [test_storage.sh](../test_storage.sh) | T65 | Storage leases, project isolation and released-slot reuse |
| [test_sessions.sh](../test_sessions.sh) | T67 | Launch limits, overrides and lazy BuildKit dispatch |
| [test_teardown.sh](../test_teardown.sh) | T69 | Delayed exit notifications and bounded container removal |
| [test_nested_retry.sh](../test_nested_retry.sh) | T70 | Narrow browser-build recovery and retained crash evidence |
| [test_image_archive.sh](../test_image_archive.sh) | T71 | Save failures and corrupt, truncated or missing archives |
| [test_rancher_dns.sh](../test_rancher_dns.sh) | T72 | Daemon config preservation, readiness and resolver checks |

T67 additionally uses a real image to test PID 1, 256 orphaned children
under a 64-task limit, exit status and SIGTERM forwarding. T66 runs
[test_concurrent.sh](../test_concurrent.sh) with three live sandboxes.
T68 runs [test_dns.sh](../test_dns.sh) against a real container. These
integration portions need an engine and the suite image.

T60 runs [test_nested.sh](../test_nested.sh) inside the sandbox. It builds
real services with cache, secret and SSH mounts, multi-stage builds and
multi-platform OCI export, then runs PostgreSQL and Playwright Chromium
as non-root users. Registry, package and browser downloads need network
access. Dependencies are installed in the nested image.

## Selecting tests and budgets

| Variable | Effect | Default |
|---|---|---|
| `SAGENT_TEST_SKIP` | Space-separated IDs to skip, reported as SKIP | none |
| `SAGENT_TEST_SHARD` | `k/n` selects every nth test starting at k | entire suite |
| `SAGENT_TEST_TMPDIR` | Directory for bind-mounted fixtures | `/tmp` |
| `TEST_TIMEOUT_SECONDS` | Timeout per test body | `600` |
| `SAGENT_TEST_NESTED_TIMEOUT_SECONDS` | Separate T60 budget | `TEST_TIMEOUT_SECONDS` |
| `FAIL_OUTPUT_LINES` | Console tail on failure | `30` |
| `SAGENT_TEST_LOG_DIR` | Retain failed and recovered-build captures | unset |

```bash
SAGENT_TEST_SKIP="T02 T10 T10b T31" SAGENT_TEST_SHARD="1/2" bash test_e2e.sh
```

Shards use file order, including skipped tests, so all slices together
cover each test once. There is no include-only filter. Run a standalone
script for a focused check.

For macOS engines that share only the home directory, put fixtures there:

```bash
mkdir -p "$HOME/sagent-test"
SAGENT_TEST_TMPDIR="$HOME/sagent-test" bash test_e2e.sh
```

The suite supplies the wrapper's keep-id mapping when it creates fixtures
under rootless Podman. Test setup and engine recovery run outside each
test body's timeout.

### Linux from a macOS host

Use a VM with the checkout and a supported engine, or the repository's
devcontainer:

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash test_e2e.sh
```

## CI matrix

[ci.yml](../.github/workflows/ci.yml) defines the jobs and conditions.
Main pushes and same-repository PRs run integration tests. Other PRs run
lint and title checks. Release PRs skip test and lint jobs; if a workflow
is started for one, only `what-ran` runs. No checks on an automated release
PR is also expected; see [release checks](releasing.md#release-checks).

| Job | Environment |
|---|---|
| `what-ran` | Reports why the workflow's jobs run or skip |
| `commit-lint`, `lint`, `lint-macos` | PR title and pre-commit hooks on Linux and macOS |
| `test-linux` | Docker CLI and Docker daemon |
| `test-linux-podman` | Rootless Podman CLI and daemon |
| `test-linux-docker-cli-podman` | Docker CLI against a rootful Podman API; rootless API rejected |
| `test-linux-podman-shim` | Podman exposed as the `docker` command |
| `test-devcontainers` | Devcontainer builds and full suite inside Docker-in-Docker |
| `build-macos-image` | Linux build of the trimmed macOS test image |
| `test-macos (1/2, 2/2)` | Two Colima shards on separate Intel macOS runners |
| `test-macos-rancher (1/2, 2/2)` | Two Rancher Desktop dockerd shards on separate Intel macOS runners |

The macOS image disables optional tools, Go, Rust and Java, and matches
the runners' UID/GID. All four macOS consumers verify the archive's SHA-256
before loading and check the wrapper's computed image tag. Save failures
stop publication. These jobs skip T02, T10, T10b and T31, whose full builds
run on Linux, and T12b, whose `/tmp` workspace is outside their VM shares.

Colima uses [colima-ci.yaml](../.github/colima-ci.yaml) for VM and container
resolvers. Rancher uses [configure-rancher-dns.sh](../.github/configure-rancher-dns.sh)
to merge resolvers into the guest Docker config, restart Docker and wait
for readiness. Both run container DNS preflight checks before E2E. These
settings apply to fresh hosted CI VMs, not users' engines.

CI uses 1200 seconds per test, 3600 for T60 on macOS, and 160 minutes per
macOS job. Mac engine probes use `SAGENT_ENGINE_TIMEOUT_SECONDS=60`.

## Diagnostics and recovery

Tests run under `bash -ec`; use `if` for expected failures and `|| true`
only when a result does not matter. The harness traces the test shell,
not the wrappers it launches. Capturing shell functions or groups can also
capture trace lines, so assert on external command output instead.

The harness prints the failed output's tail. Set `SAGENT_TEST_LOG_DIR` for
complete captures. CI uploads available `diagnostics-*` captures even
when tests pass, retaining them for seven days. An upload step alone does
not mean the tests failed.

T60 prints the full BuildKit log, PID/memory counters and fatal header on
failure. The fixed browser build can retry once with a fresh client session
and cached layers for exactly a missing-session deadline, or status-read
EOF accompanied by a new daemon `SIGILL`. Both attempts share the test
budget and their evidence is retained; a second failure fails the test.
A recovered test reports `RETRY(buildkit) PASS`. This mitigation does not
resolve the crash or retry user builds. See [known issues](../BUGS.md).

The harness separately retries an engine-disconnection failure once;
assertion failures are not retried. Container removal retries only missing
exit notifications or removal already in progress, at most six attempts.
For artifact-download failures before tests start or unassigned runner
failures, inspect the setup log and retry the failed job once the workflow
finishes. Repeated failures need investigation; do not classify skipped
tests as passing.
