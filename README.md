# release-checks

Shared GitHub Actions workflows for the release gates of a few app repos:

- **content tag and `pin`:** every commit names its image by a content tag
  (`x-<16 hex>`, a hash of the image's inputs) and its digest. The check
  verifies both against the tree and the registry.
- **`image-ref`:** the image job records the tag and digest it produced, as an
  artifact.
- **release:** pushing a reviewed `v*` tag publishes the GitHub Release, without
  building anything or running the caller's code.

## Using it

Call a workflow from your repo's `.github/workflows/`, pinned by full commit SHA:

```yaml
jobs:
  pin:
    uses: greghaskins/release-checks/.github/workflows/pin.yml@<40-hex sha>
    permissions:
      contents: read
      packages: read
```

Per-repo settings, such as the content-tag inputs and the image name, are inputs
set in your workflow. Keep them under `.github/`.

## Rules

- Everything a gate decides with lives in this repo or in the caller's
  `.github/`.
- No secrets are stored here, and no workflow uses `pull_request_target`.
- Every action is pinned to a full commit SHA.
- The caller's job sets the token's permissions; workflows here never ask for
  more than they need.

The `lint` workflow checks the second and third rules with
`.github/scripts/repo-rules.sh`. It is a strict text check of every YAML file,
not a YAML parser, so a match in a comment fails too.

## Changes

Every change is a pull request. It needs a passing `lint` check and an approval
from a code owner who did not author it or push its last commit. Repo admins
may merge a pull request without them. Nobody can push to `main` directly or
force-push it, so every commit a caller pins stays on `main`.

Callers move to a new version by changing the pinned SHA in their own repo.
