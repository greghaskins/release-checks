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

### Content tag

`.github/scripts/content-tag.sh <repo root> <inputs file> [rev]` prints
`x-<16 hex>`: the first 16 hex digits of a SHA-256 over one line per input,
`path<TAB>git object id`, sorted bytewise. The inputs file lists one path per
line (a file or a whole directory); `#` lines and blank lines are skipped. A
missing path is an error that names it. Never list the pin file: pinning would
change the tag it pins.

Image jobs, the `pin` check and a bot's pin script all run this one script, at
the SHA the caller pins, so they cannot disagree on a tag.

### `pin`

`.github/workflows/pin.yml` checks, for the caller's commit:

| Rule | Holds when | Usual fix |
|---|---|---|
| 1 | the pin file's `newTag` is this tree's content tag | run the pin script |
| 2 | the registry has that tag, under the pinned `digest` | wait for the image job, then run the pin script |
| 3 | the render references the image only as `...@<pinned digest>` | set the image only in the `images` entry |
| 4 | a tag the base already pins keeps its digest | escalate to the repo owner |

Each failure prints its rule, what is wrong and the fix. Inputs: `inputs-file`,
`image`, `pin-file`, and optionally `render-dir`, `drop-components` (render
without the kustomization's top-level `components:`, for ones CI cannot fetch)
and `pin-fix` (your repo's re-pin command, shown in failures).

The workflow reads the commit it runs at from `job.workflow_sha` and checks this
repo out there for its scripts. If that context is ever empty, set the
`release-checks-sha` input to the SHA in your `uses:` line.

The check shows up as `<your job> / pin`; require that name in your rulesets.

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
