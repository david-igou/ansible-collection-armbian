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
produces docs.ansible.com). Built and published by GitHub Actions on push to
`main`.

Result URL: `https://david-igou.github.io/ansible-collection-armbian/`.

## Approach (chosen: A — self-contained Sphinx build + modern Pages deploy)

A single `.github/workflows/docs.yml` workflow scaffolds the Sphinx project at
CI time with `antsibull-docs sphinx-init`, builds the HTML, and publishes via
`actions/upload-pages-artifact` + `actions/deploy-pages`. No Sphinx config
(`conf.py`/`build.sh`/`requirements.txt`) is committed — antsibull-docs
regenerates it fresh each run, so it always tracks the toolchain. No
`gh-pages` branch.

Rejected: (B) `ansible-community/github-docs-build` reusable workflows — heavier,
needs Surge token for previews, `gh-pages` branch flow; overkill for a
single-namespace role reference. (C) committed Sphinx scaffold + `gh-pages`
push — more files to maintain, older deploy pattern.

## What already exists (leveraged, not modified)

- All 8 roles have `meta/argument_specs.yml` + `README.md` → render as role
  reference pages.
- Collection `README.md` + `galaxy.yml` metadata → collection landing page.
- `docs/docsite/links.yml` → picked up automatically (edit-on-GitHub links,
  "Report an issue" extra link, Ansible Forum communication channel).

## New file

`.github/workflows/docs.yml` — one workflow, two jobs.

**Triggers:** `push` to `main`, `workflow_dispatch`.

**Permissions (top-level):** `contents: read`, `pages: write`,
`id-token: write`. **Concurrency:** group `pages`, `cancel-in-progress: false`.

**`build` job** (ubuntu-latest):
1. `actions/checkout` (pinned SHA, matching existing workflows).
2. `actions/setup-python` @ 3.13 (pinned SHA, matching existing workflows).
3. `pip install --upgrade pip antsibull-docs` (bootstraps sphinx-init).
4. Install the collection into the `ansible_collections/david_igou/armbian`
   tree so `--use-current` finds it:
   `ansible-galaxy collection install . --force`,
   plus `ansible-galaxy collection install -r requirements.yml` and
   `-r playbooks/routeros/requirements.yml` so doc import resolves all
   referenced collections cleanly.
5. `antsibull-docs sphinx-init --use-current --squash-hierarchy --dest-dir
   build/docsite david_igou.armbian` (squash → single-collection site, no
   all-collections nav).
6. `pip install -r build/docsite/requirements.txt` (sphinx,
   sphinx-ansible-theme, etc.).
7. `build/docsite/build.sh` → HTML at `build/docsite/build/html`.
8. `actions/upload-pages-artifact` (v5.0.0, SHA
   `fc324d3547104276b827a68afc52ff2a11cc49c9`) with `path: build/docsite/build/html`.

**`deploy` job** (ubuntu-latest, `needs: build`):
- `environment: { name: github-pages, url: ${{ steps.deployment.outputs.page_url }} }`.
- `actions/deploy-pages` (v5.0.0, SHA `cd2ce8fcbc39b97be8ca5fce6e763baed58fa128`).

Pinned-SHA style and Python 3.13 match the existing `tests.yml` / `release.yml`.

## Manual prerequisite (already done)

Repo **Settings → Pages → Source = "GitHub Actions"**. Confirmed set by the
user. The workflow cannot configure this itself.

## Out of scope (deferred)

- RST conversion of prose docs (`architecture.md`, `lifecycle.md`,
  `daily-operations.md`, `boot-mode-override.md`, `retry-configuration.md`,
  the runbook) and `docs/docsite/extra-docs.yml` registration.
- PR preview deploys.
- Updating `galaxy.yml`'s `documentation:` link to the Pages URL.
- Local `make docs` target.

## Verification

- `actionlint` / YAML lint clean on the new workflow (repo runs `make yamllint`).
- Workflow run on `main` succeeds; `deploy` job surfaces the live `page_url`.
- Docsite renders the collection index + all 8 role reference pages with
  edit-on-GitHub links and the extra/communication links from `links.yml`.
