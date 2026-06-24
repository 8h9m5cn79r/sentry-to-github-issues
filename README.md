# Sentry → GitHub Issues

A tiny GitHub Action that polls [Sentry](https://sentry.io) on a schedule and
opens a **GitHub issue for each new Sentry issue** — so crashes and errors
surface as tracked work without anyone watching the Sentry dashboard. Each issue
carries a link back, the key metadata, and the most recent event's **stack
trace** inline.

Built because Sentry's native "create a GitHub issue" alert action is gated
behind the **Business** billing plan. This needs only a free-plan, **read-only**
Sentry token and the public API.

- **Deduplicated** — a hidden `sentry-id:` marker in each filed issue is read
  back across all label-tagged issues (open *and* closed), so a given Sentry
  issue is filed exactly once, even after its GitHub issue is closed.
- **Stack trace inline** — fetched from the events/latest API, in a collapsed
  `<details>` block. Best-effort: if it can't be fetched, the issue is still
  filed without it.
- **Backlog-safe** — capped per run (`max_per_run`, default 25) and a
  `lookback_hours` window, so a flood of old issues can't open hundreds at once.
- **No dependencies** — pure `gh` + `jq` + `curl`, all preinstalled on
  `ubuntu-latest`.

## Quickstart

**1. Create a Sentry auth token.** Sentry → Settings → Auth Tokens → *Create New
Token*, scopes `project:read`, `event:read`, `org:read` (all read-only).

**2. Add it to the target repo** as a secret named `SENTRY_AUTH_TOKEN`:

```sh
gh secret set SENTRY_AUTH_TOKEN --repo OWNER/REPO
```

**3. Add the workflow.** Drop this into `.github/workflows/sentry-issues.yml`
(also in [`examples/`](examples/sentry-issues.yml)), filling in your org +
project slugs:

```yaml
name: sentry-issues
on:
  schedule:
    - cron: "17,47 * * * *"   # every 30 min (UTC)
  workflow_dispatch:
permissions:
  contents: read
  issues: write
concurrency:
  group: sentry-issues
  cancel-in-progress: false
jobs:
  file:
    runs-on: ubuntu-latest
    steps:
      - uses: caezium/sentry-to-github-issues@v1
        with:
          sentry_org: your-org-slug
          sentry_projects: "your-project"        # space-separated for several
          sentry_auth_token: ${{ secrets.SENTRY_AUTH_TOKEN }}
```

That's the whole per-project setup: **one workflow file + one secret.** Trigger a
first run from the Actions tab (`Run workflow`) to confirm it works.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `sentry_org` | yes | — | Sentry organization slug. |
| `sentry_projects` | yes | — | Space-separated Sentry project slug(s). |
| `sentry_auth_token` | yes | — | Read-only Sentry token (`project:read`, `event:read`, `org:read`). |
| `sentry_host` | no | `https://sentry.io` | Base URL; set for self-hosted Sentry. |
| `query` | no | `is:unresolved` | Sentry issue search query. |
| `lookback_hours` | no | `24` | Only file issues first seen within this window. |
| `max_per_run` | no | `25` | Cap on issues created per run. |
| `label` | no | `sentry` | Label on filed issues (created if missing; used for dedup). |
| `repo` | no | current repo | Target `owner/name` to file issues in. |
| `github_token` | no | `github.token` | Token with `issues:write` on the target repo. |

The job must grant `issues: write` (and `contents: read`). On the first run the
`label` is created automatically.

## How dedup works

Every filed issue ends with a marker line:

```
<sub>sentry-id: BURROW-1A — managed marker, do not edit or remove …</sub>
```

Before filing, the action lists all `label`-tagged issues (`--state all`),
greps their bodies for `sentry-id:`, and skips any short-id it finds. Closing a
filed issue is therefore permanent — it won't be re-opened on the next run.
Don't edit or remove that marker line.

## Prefer no third-party action?

The whole thing is one script: [`sentry-issues.sh`](sentry-issues.sh). Vendor it
into your repo and call it from a workflow step with the same environment
variables the [`action.yml`](action.yml) sets — no dependency on this repo.

## License

[MIT](LICENSE).
