# Host state in the sandbox

The wrapper mounts a few host directories into the sandbox and copies
credentials and configuration into its volumes. This page lists each piece,
how it gets there, and the setting that changes it. [Security](security.md)
covers what that exposes. [Storage layout](storage-layout.md) covers where
it lands.

## The workspace

The wrapper mounts the current directory read-write at the same path, so
paths in transcripts and tool state match on both sides. It refuses `/` and
a path with a colon in it.

## The drop folder

The wrapper creates `~/sagent-drop` when it starts and mounts it read-write
at the same path. Put a file there, then drag it onto the terminal or paste
its path, and the agent can open it. A file the agent writes there is on
your disk.

`SAGENT_DROP_DIR` names an existing folder instead. The wrapper refuses a
relative path, a missing directory, `/`, a path with a colon, and the
workspace itself.

To have macOS save screenshots there:

```bash
mkdir -p ~/sagent-drop
defaults write com.apple.screencapture location ~/sagent-drop
```

## Extra mounts

`SAGENT_EXTRA_MOUNTS` lists more host folders to mount, separated by
commas. Each one is mounted at the same path inside and is read-only unless
it ends in `:rw`. Nothing is mounted by default.

```bash
sclaude config set SAGENT_EXTRA_MOUNTS "~/Screenshots, ~/data/models:rw"
```

Each folder must already exist. The drop folder's checks apply to each
one, and a folder that is already mounted, as the workspace, the drop
folder or an earlier entry, is refused. A path with a comma in it cannot be
listed. `sclaude status` shows what is mounted.

## Clipboard

The host clipboard is shared both ways, text and images. In the sandbox,
`pbcopy`, `pbpaste`, `xclip`, `xsel`, `wl-copy` and `wl-paste` are shims
that send requests to a helper the wrapper runs on the host. Ctrl+V pastes
a host screenshot into either agent. `xclip -t image/png < shot.png`
inside puts an image on your clipboard.

Codex reads clipboard images over X11. The sandbox therefore runs a small
headless X display on `DISPLAY=:99` whose clipboard the host helper serves.
Both wrappers start it whenever the bridge is on.

The bridge works on macOS and on Linux desktops with a clipboard command.
`SAGENT_CLIPBOARD=0` turns it off. Reads then fail. Copies go out as OSC 52,
a terminal escape sequence that sets the host clipboard when the terminal
allows it.

## Sessions

Session transcripts are shared through bind mounts. A conversation started
on the host can be continued inside with `sclaude --continue` or picked
with `sclaude --resume`, and one started inside can be continued outside.
For Claude Code the shared directory is this workspace's transcripts under
`~/.claude/projects`, or under `CLAUDE_CONFIG_DIR` when you set it. For
Codex it is the whole `~/.codex/sessions` tree, which Codex does not split
per project.

Sessions the sandbox recorded before sharing existed move out to the host
on the next run, unless the host already has one by that name.

The agent can read and write those transcripts. `SAGENT_SESSIONS=0` keeps
them out. Sessions started inside then stay in the config volume.
`SAGENT_SESSIONS=all` also shares `~/.claude/file-history`, the snapshots
`/rewind` restores. That store holds file contents from every workspace.

The settings file is sourced, so you can share Claude's per-workspace
transcripts and keep Codex's all-workspace tree out:

```bash
[ "$SCRIPT_NAME" = scodex ] && SAGENT_SESSIONS=0
```

## git and gh

The wrapper copies your global git config in on every run: identity,
aliases, preferences, and the excludes file. It drops keys it knows as
host-only: credential helpers, signing, editor, pager, diff and merge
tools, and settings that name a host path. The filter works on key names.
A host path inside an alias goes through. Commits in the sandbox are
unsigned. `git config --global` inside the sandbox writes `~/.gitconfig`,
which git reads after the copied file and which persists.

When the host has `gh` logins, the wrapper writes one token per host to the
sandbox's `hosts.yml`, and git uses them for HTTPS. When the host has no
login, the sandbox keeps the file from the last run.

## SSH or HTTPS

`SAGENT_GIT_PROTOCOL` selects `ssh` or `https` for GitHub. Unset, the
wrapper follows the `git_protocol` your host `gh` has for github.com, and
uses `https` when gh has none.

With `ssh`, the wrapper copies the regular files directly under `~/.ssh`:
keys, config, known_hosts. It skips subdirectories and symlinks. Your SSH
agent is not forwarded, so a key with a passphrase asks for it inside.

With `https`, no keys go in. The wrapper removes the files it copied on an
earlier ssh run and leaves keys made inside the sandbox alone. Remotes of
the form `git@github.com:` are rewritten to HTTPS for every host gh is
logged in to.

## Sign-in and credentials

Each wrapper copies the sign-in for its own agent. Claude's comes from the
macOS keychain, or from the credentials file on Linux. Codex's is
`auth.json` under `~/.codex`, or under `CODEX_HOME` when you set it.

The newer copy wins. Claude compares `claudeAiOauth.expiresAt` and Codex
compares `last_refresh`. Refresh tokens rotate, and copying an older host
token over a newer sandbox one would sign the sandbox out. Codex copies the
host file when either side lacks the timestamp, which is the case for an
API key sign-in. Nothing is copied back to the host.

Signing in inside the sandbox needs no browser there. Open the printed link
on the host. Claude Code uses its paste-a-code flow, and `scodex login`
uses device-code sign-in.

## MCP servers

Add servers with the CLI's own command, run in the sandbox:

```bash
sclaude mcp add --transport http name URL
scodex mcp add name -- command
```

They persist in the config volume. A stdio server's command must exist in
the sandbox, in the image or installed into a volume, and `npx` does. For
Claude, `--scope project` writes the workspace's `.mcp.json`, which the
host sees too. Management subcommands such as `mcp` and `plugin` run
without the yolo flag.

For Codex, the wrapper copies the host's `config.toml` again only when its
contents change or the sandbox copy is missing. Servers added inside stay
until you edit the host file. Deleting the host file leaves the sandbox
copy in place.

## Container tooling

`docker` and `podman` inside the sandbox run through nested rootless podman.
The host engine socket is never mounted. `--no-docker` or `SAGENT_DOCKER=0`
turns this off and restores the default seccomp and AppArmor profiles. See
[nested containers](security.md#nested-containers).

## Terminal

The wrapper forwards terminal identity such as `TERM_PROGRAM`, so the CLI
can use the same shortcuts and link handling it uses on the host. With
Claude Code's mouse tracking on, hold Option (iTerm2) or Shift for native
terminal selection.

## Attribution

By default the image sets Claude Code's `attribution.commit` and
`attribution.pr` to empty strings in a managed policy file. Commits then
carry no `Co-Authored-By` trailer and pull requests no "Generated with"
line, and nothing in the config volume can override that.
`SAGENT_AI_ATTRIBUTION=1` leaves the policy out of the next image build, so
Claude's own settings decide.

Codex has no local switch. Whether it signs is a setting of the ChatGPT
workspace you sign in with, which the CLI fetches on each run. The wrapper
does not change it.
