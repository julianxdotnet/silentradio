# Silent Radio fresh provisioning

This is a **new, versioned fresh-setup artifact**, prepared from read-only production
catalog metadata and this repository's frontend. It has not been applied to any
hosted database. It is not a migration for an existing
Silent Radio database. The historical production provisioning workflow was not
present in this repository and has not been reconstructed as a deployment pipeline.

The source frontend is `index.html` at commit
`0c75f1dfa9aa4173e79b7286bdae6135f3b4edc2`, currently configured for production
project `pceoazjrgwrgxvrkvqbm`. No frontend code or existing configuration was changed.
Do not use that production target for fresh-setup tests.

## Scope and access contract

`v1/setup.sql` creates both current public tables, their constraints/indexes and
timestamp trigger, the five existing RPC overloads, and their current RLS policies.
Function bodies and their deliberate callable-role contract are preserved from
the live catalog. The application continues to use capability-style edit tokens;
this artifact does not introduce user accounts, rotate tokens or redesign ownership.

| Object | anon / authenticated | Purpose |
| --- | --- | --- |
| playlists | SELECT on id, slug, title, subtitle, creator_name, created_at, published | Public feed and playlist display; published is also needed by tracks RLS |
| tracks | SELECT | Public tracks belonging to a published playlist |
| create_silent_radio (both overloads) | EXECUTE | Create a playlist and its tracks; return the creator's edit capability |
| get_silent_radio_by_edit_token | EXECUTE | Load a playlist when its capability token is supplied |
| update_silent_radio (both overloads) | EXECUTE | Update a playlist and replace its tracks when its token is supplied |

Known inherited limitation: calling the shorter three-argument create or
four-argument update shape in SQL raises `42725` (`ambiguous_function`), because
the newer overloads have defaulted `creator_name` parameters. The recovered
definitions are preserved exactly. The current frontend supplies `creator_name`
explicitly and uses the unambiguous four-argument create and five-argument update
shapes. Older callers need separate review; this artifact does not repair their
overload ambiguity or claim hosted PostgREST dispatch compatibility.

No direct client INSERT/UPDATE/DELETE grants are needed by the inspected frontend:
`save()` calls the RPCs. No service-role table grants are inferred because no backend
table consumer was found in this application. Inherited table privileges are cleared
**only on the two newly created objects**, then the explicit grants above are added. This
works whether the platform initially supplies legacy automatic table grants or the
October 30 restricted defaults. No schema-wide default privileges are changed.

The live RPC EXECUTE contract remains callable by PUBLIC, anon, authenticated and
service_role, with schema USAGE. Keeping the existing capability endpoints callable
is intentional; the security boundary is possession of an edit token. RLS, the
five RPC bodies and the timestamp trigger are preserved. This is not a general
function-security hardening change.

## Run only in a disposable fresh target

Prerequisites: PostgreSQL 17-compatible behavior, a `public` schema, existing Supabase
roles `anon`, `authenticated`, `service_role`, and execution as the `postgres` owner.
Core `gen_random_uuid()` is used; pgcrypto and sequences are not required. The file
refuses to run if either Silent Radio table or any of its function names already
exists. It is transactional and contains no DROP, data reset, seed rows or credentials.

After reviewing the target and SQL, an operator can run it with a direct owner SQL
connection, for example `psql "$DISPOSABLE_DATABASE_URL" -v ON_ERROR_STOP=1 -f v1/setup.sql`.
Do not point this at production. No database or API key is created by these files.
Hosted project creation, credentials, exposed-schema configuration, Auth, Storage,
Realtime, hosting and deployment are outside this artifact.

For an eventual full HTTP test, use an already authorized disposable Supabase target
and point a separate frontend copy at that target's public configuration. Verify
feed display, playlist display, create, valid-token edit and invalid-token rejection.
The repository's unchanged frontend still targets production; running its UI is
not part of the isolated tests below.

## Reproduce isolated verification

From this directory, run `npm ci --ignore-scripts` followed by `npm test`.
The pinned development dependency is PGlite 0.5.11; tests create in-memory PostgreSQL
databases with synthetic fixtures and no network database connection. They load
the actual `v1/setup.sql`, exercise the current frontend's create/get/update flows
and role access, and reject replay over existing application objects. The shorter
overload ambiguity is captured as an expected inherited limitation, not a passing
legacy application flow. Test output includes the tested SQL hash.
No real edit tokens or application rows are used or logged.

The latest isolated run passed **58 checks**. It verifies published feed and track
reads, caller-only token return through RPCs, valid-token updates with track
replacement, invalid-token rejection without changes, and rollback after malformed
replacement input. Both API client roles are denied direct writes and token reads.
Draft playlists and their tracks stay hidden from public reads. The complete flow
also works when legacy default table grants are preseeded: the new objects receive
the intended allowlist while the default privileges themselves remain unchanged.
Missing roles, wrong owner, existing tables/functions, and unexpected inherited
token access cause atomic setup failure. No extra extension is installed.

For real PostgreSQL 17 verification, run `bash tests/postgres17.sh` with Docker
available. CI also runs this suite. It starts the official `postgres:17` image with
networking disabled, no published ports, a temporary in-memory data directory and
Unix socket access. It creates no passwords or persistent database credentials and
removes the container on exit. The exact setup file is checked under both restricted
and legacy table defaults, including role/column privileges, current RPC flows,
denied reads/writes, transactional rollback and refusal to replay over existing data.

These tests establish PostgreSQL ACL/RLS/RPC behavior in isolated engines. Hosted
PostgREST routing, GraphQL, deployment and unknown consumers still require a separate
disposable Supabase integration test before hosted provisioning.

## Separate live security remediation

The production database previously had a broader SELECT grant that could expose
`playlists.edit_token`; the frontend itself does not request that field publicly.
A separately approved safe-column SELECT patch was applied to production on
2026-10-24 UTC and independently verified.
**Do not apply this fresh baseline as that patch.** It intentionally refuses the
existing objects. Existing-token rotation and creator edit-link recovery require a
separate decision and are not included in either this fresh setup or the narrow
column-access patch.

## Provenance and limits

The repository previously contained only `index.html` and `deploy-trigger.txt`.
There was no SQL baseline, migration runner, CI or documented deployment pipeline.
`v1/provenance.json` records the metadata snapshot and upstream commit used for this
reconstruction. Original migration ordering, out-of-band configuration, additional
consumers and pending unpublished schema changes remain unknown. This minimal
artifact makes the observed two-table application reproducible without pretending
those missing operational details have been recovered.

The official [October 30 change notice](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically)
requires explicit object grants for new public tables; existing tables keep their
access. See also [API security](https://supabase.com/docs/guides/api/securing-your-api).
