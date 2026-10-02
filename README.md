# homeport-sh/deploy

Ship a compiled binary to a [homeport](https://homeport.sh) box from GitHub
Actions.

```yaml
name: Deploy
on:
  push:
    branches: [main]

permissions:
  id-token: write     # mint the OIDC token
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: oven-sh/setup-bun@v2
      - run: bun install --frozen-lockfile
      - run: bun build --compile --target=bun-linux-x64 ./src/index.ts --outfile server

      - uses: homeport-sh/deploy@v1
        with:
          artifact: ./server
```

There's no app to name either: the deploy lands on the environment that
follows the branch this run is on (`main` → production, `staging` →
staging). Only a repository holding several apps says which, with `app:`.

Note what is missing: **`secrets:`**. There is no deploy key to paste, nothing
to rotate, and nothing in your repository for anyone to steal.

## How it works

GitHub can mint a short-lived, signed token that says *which workflow run, in
which repository, on which ref* is asking. This action requests one, and
homeport verifies it against GitHub's published keys.

```
 your runner                          homeport                  your box
     │                                    │                         │
 1. build → ./server                      │                         │
 2. request an OIDC token                 │                         │
 3. POST /v1/deployments ──────────────►  │                         │
     │                              verify: signature, issuer,      │
     │                              audience, repository, ref       │
     │  ◄─────────────  upload URL + completion token               │
 4. PUT ./server ──────────────────────►  object storage            │
 5. POST …/complete ───────────────────►  │                         │
     │                              validate the bytes that landed  │
     │                                    │ ── deploy ────────────► │
     │  ◄─────────────  live, or why not  │                         │
```

The token is single-use and expires in minutes. The binary goes straight to
object storage, so it never passes through the control plane. And the action
waits for the box's answer rather than reporting success at the upload — if the
app does not come up, the job fails with the reason the box gave.

## Inputs

| | | |
| --- | --- | --- |
| `app` | — | Which app, only in a repository that holds several. Otherwise the environment following this run's branch. |
| `artifact` | **required** | Path to the compiled Linux binary. |
| `api-url` | `https://api.homeport.sh` | The homeport API. |
| `audience` | `https://api.homeport.sh` | The OIDC audience to request. |
| `timeout` | `600` | Seconds to wait for the deploy to finish. |

Outputs: `deployment-id` and `status`.

**Do not set `audience` to GitHub's default.** That default is your repository
owner's URL, which a token minted for an entirely different service also
satisfies — a custom audience is what makes a token minted for homeport usable
only at homeport.

## Requirements

- **`permissions: id-token: write`** on the job. Without it GitHub mints no
  token and the action stops immediately, with that as the reason.
- **A Linux binary matching your box's architecture.** The action checks for
  ELF magic before uploading, so a macOS build fails in a second rather than
  after an upload; the architecture itself is checked on arrival.
- An environment in homeport must follow the branch you are pushing, with its
  build source set to **CI**. An environment homeport builds from its pushes
  refuses uploads, so nothing deploys twice.

## Why not a deploy key

A deploy key is a long-lived credential sitting in a third party's GitHub
organisation, outside anyone's control, indefinitely. Whoever can push a
workflow can read it — so can a compromised marketplace action, so can any org
member, so can a leaked PAT with repo scope. It cannot be rotated without you
acting, and "keep it secure" is advice, not a control.

The fix is not a better warning. It is having nothing to leak.
