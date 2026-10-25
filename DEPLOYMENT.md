# Deployment and database readiness

This repository's live Cloudflare Pages configuration was inspected read-only on
2026-10-25 (Mac local date):

| Setting | Observed value |
| --- | --- |
| Git repository | julianxdotnet/silentradio |
| Production branch | main |
| Automatic deployments | Enabled |
| Preview branches | All non-production branches |
| Build command | Empty |
| Build output directory | `.` |
| Root directory | Empty (repository root) |
| Build watch inclusion | `*` |
| Deployed production commit | `0c75f1d` |

No Cloudflare settings were changed. Before this preparation, the repository had
only `index.html` and `deploy-trigger.txt`: no GitHub Actions, database runner or
build script. GitHub reported zero workflow runs. `deploy-trigger.txt` is a marker
file, not an executable deployment or migration mechanism.

## Review the compatibility changes without deploying

The new `.github/workflows/supabase-provisioning.yml` only runs isolated database
tests on pull requests, relevant main-branch pushes or manual dispatch. It has
read-only repository permission, does not persist checkout credentials, uses pinned
action revisions, and needs no Supabase secrets or hosted target. It does not run
SQL against production, push changes, upload assets or deploy.

A normal branch push would trigger a public Cloudflare preview of the repository
root. To publish a review branch/draft PR without a Pages deployment, prefix each
branch commit message with **`[CF-Pages-Skip]`**. Cloudflare documents this specific
prefix as an ad hoc deployment skip. Use it instead of generic `[skip ci]`, so the
GitHub test workflow can still run. Verify that no new Pages deployment was created
after any approved push. Keep the PR draft and do not merge until separately reviewed.

Source: [Cloudflare commit-message deployment skips](https://developers.cloudflare.com/pages/configuration/git-integration/github-integration/#skipping-a-build-via-a-commit-message).

## Keep website publication and database provisioning separate

The current output directory `.` means a normal build can publish newly added SQL,
documentation and test files as site assets. They contain no secrets or user data,
but they are not website assets. The dependency-free local builder
`node scripts/build-site.mjs` stages only the explicitly allowed `index.html` in
`dist/`. CSS, JavaScript and icons are inline; fonts and application data use
external services. Add future local assets to the builder's allowlist deliberately.
It clears only generated entries inside `dist/`, refuses a symlink at `dist`, and
does not modify the frontend. The generated directory is ignored by Git.

Before a future non-skipped deployment, approve these exact Cloudflare settings:

| Setting | Prepared future value |
| --- | --- |
| Build command | `node scripts/build-site.mjs` |
| Build output directory | `dist` |
| Root directory | Empty (repository root) |

These settings have **not** been applied and no deployment has been made. Until
they are approved and applied, retain the `[CF-Pages-Skip]` commit protocol above.
The current frontend is unchanged and still targets the existing production
Supabase project. The site builder does not execute database provisioning or tests.

CI loads the versioned [fresh database setup](supabase/provisioning/README.md) only
into disposable in-memory databases. Neither CI nor Cloudflare applies it to hosted
databases. It refuses existing application objects and is intended
for an explicitly approved disposable/new target. It must not be used to update or
reset the live database. The separately approved production token-column fix has
already been applied; no further production grant change is needed to preserve
existing-table access on October 30.

## Hosted validation gate

Local validation covers the actual current RPC signatures, grants and RLS. A hosted
PostgREST check still needs a specifically identified empty disposable Supabase
project/branch, permission to create the two-table schema and synthetic test data
there, and an agreed cleanup/retention plan. Reuse authorized existing access; do
not create a paid project, new credentials, or reset any existing dataset. There
was no disposable branch in the audited account: Silent Radio's `main` branch is
production. Do not treat it as a test target.

Publication of a draft PR, merging it, changing Cloudflare build settings,
deploying a website, and applying SQL to a hosted target are separate actions.
This compatibility package performs isolated tests; hosted fresh provisioning
remains unverified. The production security fix is recorded separately.
