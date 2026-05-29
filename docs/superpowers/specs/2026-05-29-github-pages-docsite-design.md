# GitHub Pages docsite (role reference) — design

**Date:** 2026-05-29
**Status:** approved
**Scope:** First-cut antsibull-docs → Sphinx → GitHub Pages docsite presenting
the collection + role reference. Prose docs deferred.

## Goal

Publish a GitHub Pages docsite for `david_igou.armbian` presenting the
**auto-generated collection and role reference** — built from the 8 role
`meta/argument_specs.yml`, role `README.md`s, and the collection `README.md`
— using the standard `antsibull-docs` / Sphinx toolchain (the same that
produces docs.ansible.com). Built and published by GitHub Actions.

## Approach (canonical: `ansible-community/github-docs-build` reusable workflows)

The first cut used a self-contained, hand-rolled `sphinx-init` + `build.sh`
workflow publishing a flat site via the OIDC Pages flow. On review against the
antsibull-docs documentation — which explicitly recommends the
`ansible-community/github-docs-build` reusable workflows — and the canonical
`felixfontein/ansible-acme` example, the design was changed to adopt that
maintainer-blessed pattern:

- **Build** via `_shared-docs-build-push.yml` / `_shared-docs-build-pr.yml`
  (upstream-maintained; tracks the toolchain).
- **Publish** via `_shared-docs-build-publish-gh-pages.yml`: pushes rendered
  HTML to a `gh-pages` branch under **versioned paths**
  (`branch/main`, `tag/<tag>`, `pr/<pr#>`), then deploys that branch to Pages
  via the OIDC `actions/deploy-pages` flow (`publish-gh-pages-branch: true`).
  The Pages **Source stays "GitHub Actions"** — the branch is just the
  accumulation store.
- **PR previews**: every PR gets its own docsite at `/pr/<pr#>/` plus a bot
  comment with a link and a rendered diff of which doc files changed; torn
  down when the PR closes.

Reusable workflows are pinned to a commit SHA (the repo's SHA-pinning
discipline) with a `# main` comment so Renovate keeps them current —
`github-docs-build` publishes no releases/tags to pin against.

Rejected alternatives: (A) self-contained Sphinx build + OIDC deploy — simpler
but diverges from the documented best practice, no PR previews, no versioned
publishing. (C) committed Sphinx scaffold + raw `gh-pages` push — more files to
maintain, older deploy pattern.

## What already exists (leveraged, not modified)

- All 8 roles have `meta/argument_specs.yml` + `README.md` → render as role
  reference pages.
- Collection `README.md` + `galaxy.yml` metadata → collection landing page.
- `docs/docsite/links.yml` → picked up automatically (edit-on-GitHub links,
  "Report an issue" extra link, Ansible Forum communication channel).

## New files

**`.github/workflows/docs-push.yml`** — `Docs` workflow. Triggers: push to
`main`, push tags `*`, daily `cron: '0 6 * * *'` (catches breakage from newer
antsibull-docs/theme releases), `workflow_dispatch`.
- `build-docs` (`contents: read`): `_shared-docs-build-push.yml` with
  `collection-name: david_igou.armbian`, `squash-hierarchy: true`,
  `init-lenient: false`, `init-fail-on-error: true`, and branding
  (`init-project/-copyright/-title/-html-short-title`, `documentation_home_url`
  → `/branch/main/`).
- `publish-docs-gh-pages` (`contents: write`, `pages: write`,
  `id-token: write`; gated `if: github.repository == 'david-igou/...'`):
  `_shared-docs-build-publish-gh-pages.yml` with `publish-gh-pages-branch: true`
  and `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`.

**`.github/workflows/docs-pr.yml`** — `Docs` workflow on
`pull_request_target` (`opened/synchronize/reopened/closed`).
- `build-docs`: `_shared-docs-build-pr.yml` (same `with:` as push) plus
  `render-file-line` linking each changed file to its `/pr/<n>/` preview.
- `publish-docs-gh-pages`: `action` toggles `publish`/`teardown` on close or
  no-change.
- `comment` (`pull-requests: write`): `actions/ansible-docs-build-comment`
  posts/updates the PR comment with preview links + rendered file diff.

## Manual prerequisites (one-time)

1. **Settings → Pages → Source = "GitHub Actions"** — confirmed set.
2. **An orphan `gh-pages` branch must exist** — the publish job's
   `checkout ref: gh-pages` fails otherwise. Seeded with `.nojekyll` and a
   root `index.html` redirecting to `branch/main/` (which doubles as the
   site-root redirect, since versioned publishing leaves `/` empty).

## Out of scope (deferred)

- RST conversion of prose docs (`architecture.md`, `lifecycle.md`,
  `daily-operations.md`, `boot-mode-override.md`, `retry-configuration.md`,
  the runbook) and `docs/docsite/extra-docs.yml` registration.
- Updating `galaxy.yml`'s `documentation:` link to the Pages URL.

## Verification

- Local end-to-end build of the same toolchain (antsibull-docs 2.24.0):
  `sphinx-init` → `build.sh` under strict `-W` mode **succeeded**; all 8 role
  pages + index + search rendered with the `links.yml` links present.
- Every `with:` input and `needs.*.outputs.*` reference used in the two
  workflows verified to exist in the reusable workflows at the pinned SHA.
- yamllint clean (warnings only; `.github/` is not covered by `make yamllint`).
- Post-merge: `docs-push` run succeeds and the site serves at
  `https://david-igou.github.io/ansible-collection-armbian/branch/main/`
  (root `/` redirects there). A test PR shows a `/pr/<n>/` preview + comment.
