# Releasing

Releases are cut by [release-please](https://github.com/googleapis/release-please)
from conventional commits and published by
[`.github/workflows/release-please.yml`](../.github/workflows/release-please.yml).

## How a release happens

1. A push to `main` runs the workflow. It opens or updates the release PR,
   which bumps the version in both wrappers and the manifest and adds the
   changelog entry.
2. Merging the release PR runs the workflow again. It pushes the tag at the
   release commit, creates the GitHub release as a draft, uploads both
   wrappers, verifies them, and publishes the release. `latest` never points
   at a release without its wrappers.
3. The same run builds the amd64 and arm64 images, pushes them to
   `ghcr.io`, and publishes the multi-arch manifest.
4. The next release PR is built after that, from the published tag.

Merges of `docs:`, `test:`, `ci:` and `chore:` commits produce no release
PR.

## The release PR's checks

The release PR comes from `github-actions[bot]`. GitHub holds workflow runs
from bot-authored pull requests until someone approves them. Press "Approve
and run" on the PR's checks once. The one job that runs there, `what-ran`,
says that the test jobs are skipped on purpose. Left unapproved, the run
goes red and the PR looks broken when it is not.

A personal access token for release-please in place of `GITHUB_TOKEN` would
make the PR come from a human account, and its checks would start on their
own.

## Merge order

Merge the release PR and let its run finish before merging anything else.
If another PR lands on `main` first and touches a workflow file, the
release commit sits behind `main` with a workflow diff. GitHub then refuses
the Actions token both the tag and the release for that commit. The job
says so when it happens. The fix is by hand, below.

## When a release does not finish

A failure after the release exists leaves a draft, or a published release
without images. Run the workflow by hand with the tag. That path skips
release-please itself and runs the publishing jobs only, so it is safe to
repeat, and it publishes the draft too:

```bash
gh workflow run release-please.yml -f tag=v3.1.2
```

A failure before the release exists is the merge-order case above. Finish
it with your own credentials, using the version from
`.release-please-manifest.json` and the merged release PR's commit:

```bash
git push origin <sha>:refs/tags/v3.1.2
awk '/^## \[3\.1\.2\]/{f=1; next} f&&/^## \[/{exit} f' CHANGELOG.md > notes.md
gh release create v3.1.2 --draft --title v3.1.2 --notes-file notes.md
gh pr edit <release PR> --remove-label "autorelease: pending" --add-label "autorelease: tagged"
gh workflow run release-please.yml -f tag=v3.1.2
```

The label swap matters. With `autorelease: pending` still on the PR, every
later run retries that version.

If the runner queue is slow and you want the release PR now, run
release-please from your machine. It creates the same PR the workflow
would:

```bash
npx release-please release-pr --repo-url=e6qu/sclaude --token="$(gh auth token)" \
    --config-file=release-please-config.json --manifest-file=.release-please-manifest.json
```
