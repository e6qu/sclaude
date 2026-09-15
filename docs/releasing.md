# Releasing

[release-please](https://github.com/googleapis/release-please) prepares
releases from conventional commits.
[`release-please.yml`](../.github/workflows/release-please.yml) publishes
the wrappers and the container images.

## How a release happens

1. A push to `main` runs the workflow. When there are unreleased `fix:` or
   `feat:` commits, release-please opens or updates the release PR, which
   bumps the version in both wrappers and the manifest and adds the
   changelog entry.
2. Merging the release PR runs the workflow again. It pushes the tag at the
   release commit, creates the GitHub release as a draft, uploads both
   wrappers, verifies them, and publishes the release. `latest` never points
   at a release without its wrappers.
3. Separate jobs build the amd64 and arm64 images, push them to `ghcr.io`,
   and publish the multi-arch manifest.
4. Once the wrappers are published, the same run prepares the next release
   PR from the new tag. It does not wait for the image jobs.

[Commits](../CONTRIBUTING.md#commits) says which commit types request a
release.

## The release PR's checks

The workflow creates the release PR with `GITHUB_TOKEN`, and GitHub holds
the workflow runs such a PR triggers until someone approves them. Press
"Approve and run" on the PR's checks once. The one job that runs there,
`what-ran`, says that the test jobs are skipped on purpose. The tests run
on `main` after the merge. Left unapproved, the run shows as failed and
the PR looks broken.

## Merge order

After merging the release PR, let its run finish before merging anything
else. If another PR that touches a workflow file lands on `main` first,
the release commit sits behind `main` with a workflow diff, and GitHub
refuses the Actions token both the tag and the release for that commit.
The job says so when it happens. Finish the release by hand, below.

## When a release does not finish

A failure after the release exists leaves a draft, or a published release
without images. Dispatch the workflow with the tag. That path skips
release-please and runs the publishing jobs again, which replaces the
wrapper assets and rebuilds the images from the tag with the packages of
the day. It publishes the draft as well:

```bash
gh workflow run release-please.yml -f tag=v3.1.2
```

When the tag step reports the merge-order failure above, finish the
release with your own credentials. Use the version from
`.release-please-manifest.json` and the merged release PR's commit and
number:

```bash
RELEASE_SHA=0123abc
RELEASE_PR=123
git push origin "$RELEASE_SHA:refs/tags/v3.1.2"
awk '/^## \[3\.1\.2\]/{f=1; next} f&&/^## \[/{exit} f' CHANGELOG.md > notes.md
gh release create v3.1.2 --draft --title v3.1.2 --notes-file notes.md
gh pr edit "$RELEASE_PR" --remove-label "autorelease: pending" --add-label "autorelease: tagged"
gh workflow run release-please.yml -f tag=v3.1.2
```

Swap the labels, or every later run retries that version. Any other
failure before the release exists needs the job log.

To get the next release PR without waiting for a runner, let any release
in progress publish first, then run release-please from the repository
root. It creates the same PR the workflow would:

```bash
npx release-please release-pr \
    --repo-url=e6qu/sclaude \
    --token="$(gh auth token)" \
    --config-file=release-please-config.json \
    --manifest-file=.release-please-manifest.json
```
