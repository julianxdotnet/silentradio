#!/usr/bin/env bash
set -euo pipefail

# Requires only Docker. No host port, network database, password, secret, bind
# mount, installed package, or persisted database volume is used.
provisioning_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
container_id=''
replay_log="$(mktemp)"
cleanup() {
  if [[ -n "$container_id" ]]; then docker rm -f "$container_id" >/dev/null 2>&1 || true; fi
  rm -f "$replay_log"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

container_id="$(docker run --detach --rm --network none \
  --tmpfs /var/lib/postgresql/data:rw,nosuid,size=512m \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:17 postgres -c listen_addresses= -c log_statement=none -c log_min_error_statement=panic)"

ready=false
for _ in {1..30}; do
  # Ignore the entrypoint's temporary initdb server; wait for final postgres PID1.
  if docker exec "$container_id" sh -c 'test "$(cat /proc/1/comm)" = postgres && pg_isready -U postgres -h /var/run/postgresql' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  printf '%s\n' 'PostgreSQL 17 container did not become ready.' >&2
  exit 1
fi

docker exec "$container_id" mkdir -p /work/v1 /work/tests
docker cp "$provisioning_dir/v1/setup.sql" "$container_id:/work/v1/setup.sql" >/dev/null
docker cp "$provisioning_dir/tests/postgres17.sql" "$container_id:/work/tests/postgres17.sql" >/dev/null
docker exec "$container_id" psql -X -q -U postgres -h /var/run/postgresql -d postgres \
  -v ON_ERROR_STOP=1 -Atc 'SELECT version();'

for legacy_defaults in 0 1; do
  database_name="silentradio_smoke_${legacy_defaults}"
  docker exec "$container_id" createdb -U postgres -h /var/run/postgresql "$database_name"
  docker exec "$container_id" psql -X -q -U postgres -h /var/run/postgresql -d "$database_name" \
    -v ON_ERROR_STOP=1 -v "legacy_defaults=$legacy_defaults" -f /work/tests/postgres17.sql

  fingerprint_sql="SELECT md5(coalesce(jsonb_agg(to_jsonb(p) ORDER BY id)::text, '[]')) FROM public.playlists p;"
  before="$(docker exec "$container_id" psql -X -q -U postgres -h /var/run/postgresql \
    -d "$database_name" -v ON_ERROR_STOP=1 -Atc "$fingerprint_sql")"
  if docker exec "$container_id" psql -X -q -U postgres -h /var/run/postgresql -d "$database_name" \
      -v ON_ERROR_STOP=1 -v VERBOSITY=terse -f /work/v1/setup.sql >"$replay_log" 2>&1; then
    printf '%s\n' 'FAIL: setup unexpectedly accepted an existing application.' >&2
    exit 1
  fi
  if ! grep -q 'Fresh setup refused: Silent Radio objects already exist' "$replay_log"; then
    printf '%s\n' 'FAIL: replay did not fail at the expected existing-object guard.' >&2
    exit 1
  fi
  after="$(docker exec "$container_id" psql -X -q -U postgres -h /var/run/postgresql \
    -d "$database_name" -v ON_ERROR_STOP=1 -Atc "$fingerprint_sql")"
  if [[ "$before" != "$after" ]]; then
    printf '%s\n' 'FAIL: rejected replay changed the synthetic sentinel.' >&2
    exit 1
  fi
  printf 'PASS PostgreSQL 17: replay guard preserves data; legacy_defaults=%s\n' "$legacy_defaults"
done
printf '%s\n' 'PASS PostgreSQL 17 smoke suite under both default-grant regimes.'
