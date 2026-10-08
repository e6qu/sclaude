# Known issues and follow-ups

Track unresolved problems here. Fixed behavior belongs in the current
guides and regression tests; release history is in [CHANGELOG.md](CHANGELOG.md)
and [merged pull requests](https://github.com/e6qu/sclaude/pulls?q=is%3Apr+is%3Amerged).

## BuildKit SIGILL on Intel macOS VMs

A native Intel Colima CI VM reported a BuildKit `SIGILL` during browser
image export. The captured counters showed no PID-limit hits or OOM kills.
The cause remains unconfirmed. The supervisor restarted BuildKit, but the
client building that image failed with a disconnected-session error.

The fixed CI browser fixture retries once only for a missing-session
deadline, or status-read EOF accompanied by a new daemon `SIGILL`. It
retains the crash report and both attempts. This is a test mitigation;
it does not fix the crash or retry arbitrary builds run by users.

Follow-up: reproduce the daemon crash and identify its cause before
changing runtime or VM settings. Preserve `/tmp/sagent-buildkit.log` and
resource counters when reporting it. See [test diagnostics](docs/e2e-testing.md#diagnostics-and-recovery)
and the [affected CI run](https://github.com/e6qu/sclaude/actions/runs/37576642935).

## Concurrent-session capacity

The target of roughly 100 sessions on an 8-GiB, 2-vCPU VM has not been
validated. Tests cover three simultaneous sandboxes, isolated nested
stores, lazy BuildKit startup, and orphan reaping. Passing those tests
does not establish capacity for 100 agents running tests, browsers or
pre-commit hooks.

Follow-up: measure representative workloads, including active tests and
nested builds, and determine the concurrency budget from CPU, memory and
process usage. Per-session limits are ceilings, not reservations; see
[resource limits](docs/security.md#resource-limits).

## Maintaining this tracker

For an unresolved issue, record the reproducer, observed evidence,
workaround and remaining work. Remove resolved entries after the fix and
regression test land. Avoid logging each transient CI download or runner
failure as a product bug.

Legacy bug numbers in code comments refer to the
[historical tracker](https://github.com/e6qu/sclaude/blob/6670e8ae6926a35c4ea74d62ec89ffbbb2b62493/BUGS.md).
That history remains available in Git; it is not a list of current problems.
