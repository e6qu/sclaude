# Releasing

[release-please.yml](../.github/workflows/release-please.yml) uses
[release-please](https://github.com/googleapis/release-please) to prepare
version bumps and publish wrappers and images. Commit types determine
whether a release is needed; see [commits](../CONTRIBUTING.md#commits).
Documentation, test and CI changes alone do not request a new version.

## Release flow

1. A push to `main` opens or updates the release PR when there are
   unreleased release-worthy commits. It changes both wrappers' versions,
   the manifest and the changelog.
2. Merging that PR tags its merge commit and creates a draft release.
   The workflow uploads and verifies both scripts before publishing it.
   The GitHub `latest` release therefore has its wrapper assets attached.
3. Image jobs build and verify `amd64` and `arm64` images from that tag,
   then publish the multi-architecture manifest. Images can finish after
   the wrapper release is visible.
4. Once the wrapper publication succeeds, `release-pr` prepares the next
   release PR if more release-worthy commits remain. It does not wait for
   image publication.

The wrappers build their own image locally. Published images use the
release's defaults and UID/GID 1000; see [published images](image.md#published-images).
A tag can trail `main` when later commits only change tests or docs.

## Release checks

Check that the code on `main` has passing CI before cutting a release.
Release PRs intentionally skip test and lint jobs. If their CI workflow
runs, only the `what-ran` reporter runs. No jobs on a release PR is fine.

GitHub can hold workflows triggered by `GITHUB_TOKEN` PR creation for
approval. Approval is optional for this repository's release PR because
it would only start the reporter. Do not treat absent or skipped release-PR
checks as a product failure. See [GitHub's trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow#triggering-a-workflow-from-a-workflow).

After merging, monitor both `CI` and `Release Please`. Confirm the scripts
are attached to a published release and `publish-manifest` succeeded for
both architectures. Let release publication finish before merging another
workflow change: GitHub can refuse the Actions token permission to tag or
release an older commit after workflow files change.

## Check what is published

From the checkout, with authenticated `gh`:

```bash
gh release view --json tagName,isDraft,publishedAt,assets,url
gh run list --workflow release-please.yml --limit 5
git fetch origin --tags
git log --oneline "$(gh release view --json tagName --jq .tagName)..origin/main"
```

Read any commits after the tag to distinguish runtime changes from tests
and documentation. A published wrapper release does not by itself prove
its image jobs finished.

## Recover an incomplete release

If the tag and release already exist, dispatch the workflow for that tag.
It skips release-please, replaces the wrapper assets, verifies and
publishes the draft if needed, and rebuilds images from the tagged source:

```bash
release_tag=TAG_FROM_FAILED_RUN
gh workflow run release-please.yml -f tag="$release_tag"
```

Replace `TAG_FROM_FAILED_RUN` with the intended tag, including `v`.
Do not infer an unpublished draft's tag from the latest published release.
Rerun only a failed job when retaining successful jobs is appropriate.
A dispatch rebuild uses the packages available at that time.

If the job log says the Actions token cannot tag the release commit after
a workflow change, finish it with your own authenticated credentials.
Replace `RELEASE_PR_NUMBER` with the merged release PR number and run from
a checkout of that release commit, so the manifest and notes match:

```bash
release_pr=RELEASE_PR_NUMBER
release_sha=$(gh pr view "$release_pr" --json mergeCommit --jq .mergeCommit.oid)
release_version=$(jq -r '.["."]' .release-please-manifest.json)
release_tag="v$release_version"
release_notes=$(mktemp)
awk -v version="$release_version" '
    index($0, "## [" version "]") == 1 { found=1; next }
    found && /^## \[/ { exit }
    found { print }
' CHANGELOG.md > "$release_notes"
git push origin "$release_sha:refs/tags/$release_tag"
gh release create "$release_tag" --draft --title "$release_tag" --notes-file "$release_notes"
rm "$release_notes"
gh pr edit "$release_pr" --remove-label "autorelease: pending" --add-label "autorelease: tagged"
gh workflow run release-please.yml -f tag="$release_tag"
```

The label change prevents later runs from retrying that pending release.
For other failures before a tag or release exists, diagnose the job log
before choosing recovery steps.
