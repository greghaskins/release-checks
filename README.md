# release-checks

Shared GitHub Actions workflows for the release gates of a few app repos:

- **content tag and `pin`:** every commit names its image by a content tag
  (`r-<64 hex>`, a hash of the image's input set) and its digest. The check
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

### Image config

Each app has one `.github/image.json`. The build, the `pin` check and the
bots' pin script all read it, so they cannot disagree:

```json
{
  "image": "ghcr.io/owner/app",
  "dockerfile": "Dockerfile",
  "paths": ["Dockerfile", "cmd", "internal", "go.mod", "go.sum", ":(exclude)internal/testdata"],
  "pin_file": "deploy/base/kustomization.yaml",
  "target": "runtime",
  "build_args": {"APP": "app"},
  "build_args_file": "versions.env"
}
```

`target`, `build_args` and `build_args_file` are optional. `paths` are git
pathspecs; only the `glob` and `exclude` magic is allowed. The input set is
what they match, plus `.github/image.json` itself.

### Content tag

```
content-tag.sh [--list | --build-args | --config] <repo> <commit>
```

Everything comes from `<commit>`, never the work tree.

- With no mode: `r-<64 hex>`, a SHA-256 over the line
  `release-checks content tag 1` and one line per file of the input set,
  `<mode> <object id><TAB><path>`, sorted bytewise by path.
- `--list`: those files as NUL-terminated records, in the same order. The
  build context is exactly this list.
- `--build-args`: the build args, sorted `KEY=value` lines.
- `--config`: the validated config as one JSON object, with `build_args`
  merged from both sources.

A golden test vector in `.github/scripts/test.sh` fixes the format; changing
it is a new scheme and re-tags every image.

It exits 1 and prints `content-tag: <rule>: <detail>` when the config or the
input set breaks a rule: `config`, `pathspec-magic`, `no-match`,
`no-dockerfile`, `no-build-args-file`, `pin-file-in-set`, `submodule`,
`control-byte`, `symlink-escape`, `build-arg-key`, `build-arg-duplicate`,
`build-arg-value`. It exits 2 on a usage error.

### `pin`

`.github/workflows/pin.yml` checks a pull request's head commit (never the
merge commit), or the pushed commit:

| Rule | Holds when | Usual fix |
|---|---|---|
| 1 | the pin file's `newTag` is the commit's content tag | run the pin script |
| 2 | the registry has that tag, under the pinned `digest` | wait for the image job, then run the pin script |
| 3 | the render references the image only as `...@<pinned digest>` | set the image only in the `images` entry |
| 4 | a tag the base already pins keeps its digest | escalate to the repo owner |

Each failure prints its rule, what is wrong and the fix. The image and the pin
file come from `.github/image.json`. Optional inputs: `render-dir`,
`drop-components` (render without the remote entries of the kustomization's
`components:`, for ones CI cannot fetch) and `pin-fix` (your repo's re-pin
command, shown in failures).

The workflow reads the commit it runs at from `job.workflow_sha` and checks this
repo out there for its scripts. If that context is ever empty, set the
`release-checks-sha` input to the SHA you call it at.

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
