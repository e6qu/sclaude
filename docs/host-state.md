# Host state in the sandbox

What the sandbox can see of your machine, how each piece gets there, and the
setting that changes it. [Security](security.md) covers what that exposes;
[storage layout](storage-layout.md) covers where it lands.

## The workspace

The current directory is mounted read-write at the same path, so paths in
transcripts and tool state match on both sides. `/` is refused as a
workspace.

## The drop folder

`~/sagent-drop` is created on the first run and mounted read-write at the
same path. Drag a screenshot onto the terminal, or paste its path, and the
agent can open it; a file the agent writes there is on your disk.
`SAGENT_DROP_DIR` names another folder. A relative path, a missing
directory, `/`, or the workspace itself is refused.

To have macOS save screenshots there:

```bash
defaults write com.apple.screencapture location ~/sagent-drop
```

## Clipboard

The host clipboard is shared both ways, text and images. In the sandbox,
`pbcopy`, `pbpaste`, `xclip`, `xsel`, `wl-copy` and `wl-paste` are shims
that talk to an agent the wrapper runs on the host. Selecting in Claude
Code's TUI copies to your clipboard; Ctrl+V pastes a host screenshot;
`xclip -t image/png < shot.png` inside puts an image on your clipboard.

Codex reads clipboard images over X11 rather than through those commands,
so the sandbox runs a small headless X display (`DISPLAY=:99`) whose
clipboard is served from the host. Ctrl+V of a screenshot works in `scodex`
too, and what Codex copies reaches your clipboard.

This works on macOS and on Linux desktops; a headless Linux host has no
clipboard to share. `SAGENT_CLIPBOARD=0` turns the bridge off, after which
copies go out through the terminal (OSC 52) and reads fail.

## Sessions

Session transcripts are shared both ways. A conversation started on the host
can be resumed inside (`claude --resume`) and one started inside can be
resumed outside. It is one bind-mounted directory, not a copy: for Claude
Code, this workspace's transcripts under `~/.claude/projects`; for Codex, its
whole `~/.codex/sessions` tree, which it does not split per project.

Sessions the sandbox recorded before sharing existed move out to the host on
the next run.

The agent can read and write those transcripts. `SAGENT_SESSIONS=0` keeps
them out; sessions started inside then stay inside. `SAGENT_SESSIONS=all`
also shares `~/.claude/file-history`, the snapshots `/rewind` restores. That
store holds file contents from every workspace, this one included.

Because the settings file is sourced, you can share Claude's per-workspace
transcripts and keep Codex's all-workspace tree out:

```bash
[ "$SCRIPT_NAME" = scodex ] && SAGENT_SESSIONS=0
```

## git and gh

Your global git config is synced in on every run: identity, aliases,
preferences, and the excludes file. Not synced: credential helpers, signing
(commits in the sandbox are unsigned), editor, pager, diff and merge tools,
and anything naming a host path. `git config --global` inside the sandbox
writes `~/.gitconfig`, which is read after the synced file and persists.

Your `gh` login is synced in the same way, one token per host in
`hosts.yml`, and git uses it for GitHub over HTTPS.

## SSH or HTTPS

The protocol for GitHub follows your host `gh` setting, or
`SAGENT_GIT_PROTOCOL`.

With `ssh`, `~/.ssh` (keys, config, known_hosts) is synced in. Keys with a
passphrase cannot be unlocked there. With `https`, no keys go in and
`git@github.com:` remotes are rewritten to HTTPS.

## Sign-in and credentials

Your Claude sign-in (macOS keychain, or the credentials file on Linux) and
your Codex `auth.json` are copied into the config volumes. Whichever copy
is newer wins: the host's, or the one the sandbox refreshed itself. Refresh
tokens rotate, so copying an older host token over a newer sandbox one
would sign the sandbox out.

Signing in inside the sandbox works without a browser: URLs print as
clickable links, Claude Code uses its paste-a-code flow, and Codex uses
device-code sign-in.

## MCP servers

Add servers with the CLI's own command, run in the sandbox:

```bash
sclaude mcp add --transport http name URL
scodex mcp add name -- command
```

They persist in the config volume. A stdio server's command must exist in
the image; `npx` does. `--scope project` writes the workspace's `.mcp.json`,
which the host sees too. Management subcommands such as `mcp` and `plugin`
run without the yolo flag.

For Codex, a host `~/.codex/config.toml` is copied into the sandbox again
only when it changes, so servers added inside stay until you edit the host
file.

## Container tooling

`docker` and `podman` inside the sandbox run through nested rootless podman.
The host engine socket is never mounted. `--no-docker` or `SAGENT_DOCKER=0`
turns this off, which also restores the default seccomp and AppArmor
profiles; see [security](security.md#nested-containers).

## Terminal

Terminal identity (`TERM_PROGRAM` and the like) is forwarded, so Shift+Enter,
clickable links and the selection hint work as on the host. With Claude
Code's mouse tracking on, hold Option (iTerm2) or Shift for native terminal
selection.

## Attribution

Claude Code does not sign its work in the sandbox: no `Co-Authored-By`
trailer and no "Generated with" line, in commits or pull requests. A policy
file in the image sets `attribution` with both texts empty, and nothing in
the config volume can override it. `SAGENT_AI_ATTRIBUTION=1` puts the
footers back.

Codex has no local switch. Whether it signs is a policy of the ChatGPT
workspace you sign in with; the CLI fetches it on each run, with
instructions that override anything in `AGENTS.md`. An API-key sign-in has
it off.
