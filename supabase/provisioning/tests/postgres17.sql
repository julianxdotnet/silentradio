-- Disposable PostgreSQL 17 only; run through postgres17.sh.
-- Synthetic tokens stay inside PL/pgSQL variables and are never printed.
\set ON_ERROR_STOP on
\set VERBOSITY terse
\set SHOW_CONTEXT never

DO $require_pg17$
BEGIN
  IF current_setting('server_version_num')::integer < 170000
     OR current_setting('server_version_num')::integer >= 180000 THEN
    RAISE EXCEPTION 'This smoke suite requires PostgreSQL major version 17';
  END IF;
END;
$require_pg17$;

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
    CREATE ROLE anon NOLOGIN NOSUPERUSER NOBYPASSRLS;
    CREATE ROLE authenticated NOLOGIN NOSUPERUSER NOBYPASSRLS;
    CREATE ROLE service_role NOLOGIN NOSUPERUSER BYPASSRLS;
  END IF;
END;
$roles$;

\if :legacy_defaults
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLES TO anon, authenticated, service_role;
\endif

CREATE TEMP TABLE expected_defaults AS
  SELECT defaclrole, defaclnamespace, defaclobjtype, defaclacl FROM pg_default_acl;

-- The runner copies the actual repository setup file here without rewriting it.
\ir ../v1/setup.sql

BEGIN;

DO $catalog_contract$
DECLARE
  actor text;
  relation_name text;
  operation text;
  column_name text;
  expected boolean;
  actual boolean;
BEGIN
  IF EXISTS (
    (SELECT defaclrole, defaclnamespace, defaclobjtype, defaclacl FROM pg_default_acl
      EXCEPT SELECT * FROM expected_defaults)
    UNION ALL
    (SELECT * FROM expected_defaults
      EXCEPT SELECT defaclrole, defaclnamespace, defaclobjtype, defaclacl FROM pg_default_acl)
  ) THEN
    RAISE EXCEPTION 'Setup changed schema-wide default privileges';
  END IF;
  IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity) <> 2 THEN
    RAISE EXCEPTION 'Both application tables must enable RLS';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='S') THEN
    RAISE EXCEPTION 'Unexpected sequence dependency';
  END IF;
  FOREACH actor IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
    FOREACH relation_name IN ARRAY ARRAY['playlists','tracks'] LOOP
      FOREACH operation IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'] LOOP
        expected := actor <> 'service_role' AND relation_name='tracks' AND operation='SELECT';
        actual := has_table_privilege(actor, 'public.' || relation_name, operation);
        IF actual IS DISTINCT FROM expected THEN
          RAISE EXCEPTION 'Unexpected table privilege for role %, table %, operation %', actor, relation_name, operation;
        END IF;
      END LOOP;
    END LOOP;
    FOREACH column_name IN ARRAY ARRAY['id','slug','edit_token','title','subtitle','published','created_at','updated_at','creator_name'] LOOP
      expected := actor <> 'service_role' AND column_name NOT IN ('edit_token','updated_at');
      IF has_column_privilege(actor, 'public.playlists', column_name, 'SELECT') IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'Unexpected playlist column privilege for role %, column %', actor, column_name;
      END IF;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'PASS PostgreSQL 17: default ACL preservation, RLS and 75 exact object privilege assertions';
END;
$catalog_contract$;

-- Owner-only synthetic draft fixture verifies RLS independently of RPC defaults.
INSERT INTO public.playlists(id, slug, edit_token, published)
  VALUES ('00000000-0000-0000-0000-000000000001',
    'synthetic-draft', 'SYNTHETIC-ONLY-DRAFT-CAPABILITY', false);
INSERT INTO public.tracks(playlist_id, title, artist)
  VALUES ('00000000-0000-0000-0000-000000000001', 'Synthetic hidden track', 'Synthetic artist');

DO $current_frontend_flow$
DECLARE
  actor text;
  relation_name text;
  command text;
  denied boolean;
  station_slug text;
  station_token text;
  station_id uuid;
  updated_slug text;
  payload jsonb;
  before_data jsonb;
  after_data jsonb;
  before_stamp timestamptz;
  checks integer := 0;
BEGIN
  FOREACH actor IN ARRAY ARRAY['anon','authenticated'] LOOP
    EXECUTE format('SET LOCAL ROLE %I', actor);
    SELECT c.slug, c.edit_token INTO station_slug, station_token
      FROM public.create_silent_radio(
        p_title => 'Synthetic station ' || actor,
        p_subtitle => 'Synthetic subtitle',
        p_tracks => '[{"title":"Synthetic song A","artist":"Synthetic artist"},{"title":"Synthetic song B","artist":"Synthetic artist"}]'::jsonb,
        p_creator_name => 'Synthetic creator') c;
    IF station_slug IS NULL OR station_token !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'Current create RPC did not return a valid synthetic capability';
    END IF;
    checks := checks + 1;

    payload := public.get_silent_radio_by_edit_token(station_token);
    IF payload->>'slug' IS DISTINCT FROM station_slug
       OR payload->>'edit_token' IS DISTINCT FROM station_token
       OR payload->>'creator_name' IS DISTINCT FROM 'Synthetic creator'
       OR jsonb_array_length(payload->'tracks') <> 2 THEN
      RAISE EXCEPTION 'Valid-token getter failed';
    END IF;
    checks := checks + 1;

    -- Exact projections used by the current frontend; no SELECT * fallback.
    PERFORM slug, title, creator_name, created_at FROM public.playlists ORDER BY created_at DESC LIMIT 20;
    SELECT id INTO station_id FROM public.playlists WHERE slug=station_slug;
    PERFORM id, slug, title, subtitle, creator_name FROM public.playlists WHERE id=station_id;
    PERFORM title, artist, album, year, artwork_url, apple_url, spotify_url, youtube_url, feeling
      FROM public.tracks WHERE playlist_id=station_id ORDER BY position;
    IF station_id IS NULL OR (SELECT count(*) FROM public.tracks WHERE playlist_id=station_id) <> 2 THEN
      RAISE EXCEPTION 'Public frontend projections failed';
    END IF;
    checks := checks + 1;

    IF EXISTS (SELECT 1 FROM public.playlists WHERE slug='synthetic-draft')
       OR EXISTS (SELECT 1 FROM public.tracks WHERE title='Synthetic hidden track') THEN
      RAISE EXCEPTION 'Public reader can see a draft or its tracks';
    END IF;
    payload := public.get_silent_radio_by_edit_token('SYNTHETIC-ONLY-DRAFT-CAPABILITY');
    IF payload->>'slug' IS DISTINCT FROM 'synthetic-draft' THEN
      RAISE EXCEPTION 'A legitimate draft capability stopped working';
    END IF;
    checks := checks + 1;

    FOREACH command IN ARRAY ARRAY[
      'SELECT edit_token FROM public.playlists',
      'SELECT * FROM public.playlists',
      'SELECT slug FROM public.playlists WHERE edit_token IS NOT NULL'
    ] LOOP
      denied := false;
      BEGIN EXECUTE command;
      EXCEPTION WHEN insufficient_privilege THEN denied := true;
      END;
      IF NOT denied THEN RAISE EXCEPTION 'Direct token or wildcard read was not denied'; END IF;
      checks := checks + 1;
    END LOOP;
    FOREACH relation_name IN ARRAY ARRAY['playlists','tracks'] LOOP
      FOREACH command IN ARRAY ARRAY[
        format('INSERT INTO public.%I DEFAULT VALUES', relation_name),
        format('UPDATE public.%I SET title=title', relation_name),
        format('DELETE FROM public.%I', relation_name)
      ] LOOP
        denied := false;
        BEGIN EXECUTE command;
        EXCEPTION WHEN insufficient_privilege THEN denied := true;
        END;
        IF NOT denied THEN RAISE EXCEPTION 'Direct client write was not denied'; END IF;
        checks := checks + 1;
      END LOOP;
    END LOOP;

    EXECUTE 'RESET ROLE';
    SELECT updated_at INTO before_stamp FROM public.playlists WHERE id=station_id;
    EXECUTE format('SET LOCAL ROLE %I', actor);
    SELECT u.slug INTO updated_slug FROM public.update_silent_radio(
      p_edit_token => station_token, p_title => 'Updated synthetic station',
      p_subtitle => 'Updated synthetic subtitle',
      p_tracks => '[{"title":"Synthetic replacement","artist":"Synthetic replacement artist"}]'::jsonb,
      p_creator_name => 'Updated synthetic creator') u;
    payload := public.get_silent_radio_by_edit_token(station_token);
    IF updated_slug IS DISTINCT FROM station_slug
       OR payload->>'title' IS DISTINCT FROM 'Updated synthetic station'
       OR payload->>'creator_name' IS DISTINCT FROM 'Updated synthetic creator'
       OR jsonb_array_length(payload->'tracks') <> 1
       OR payload->'tracks'->0->>'title' IS DISTINCT FROM 'Synthetic replacement' THEN
      RAISE EXCEPTION 'Valid-token update did not replace the playlist and tracks';
    END IF;
    EXECUTE 'RESET ROLE';
    -- now() is transaction-stable in this suite, so >= is correct here. The
    -- PGlite suite separately verifies timestamp advancement across statements.
    IF (SELECT updated_at FROM public.playlists WHERE id=station_id) < before_stamp THEN
      RAISE EXCEPTION 'Timestamp trigger moved backwards';
    END IF;
    SELECT jsonb_build_object(
      'p',(SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.playlists p),
      't',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.tracks t)) INTO before_data;
    checks := checks + 1;
    EXECUTE format('SET LOCAL ROLE %I', actor);

    denied := false;
    BEGIN PERFORM public.get_silent_radio_by_edit_token('SYNTHETIC-INVALID-CAPABILITY');
    EXCEPTION WHEN SQLSTATE 'P0001' THEN denied := true;
    END;
    IF NOT denied THEN RAISE EXCEPTION 'Invalid get token was accepted'; END IF;
    checks := checks + 1;
    denied := false;
    BEGIN PERFORM * FROM public.update_silent_radio(
      'SYNTHETIC-INVALID-CAPABILITY'::text, 'Must not persist'::text, ''::text, '[]'::jsonb, 'Invalid'::text);
    EXCEPTION WHEN SQLSTATE 'P0001' THEN denied := true;
    END;
    IF NOT denied THEN RAISE EXCEPTION 'Invalid update token was accepted'; END IF;
    checks := checks + 1;
    denied := false;
    BEGIN PERFORM * FROM public.update_silent_radio(
      station_token, 'Must roll back'::text, ''::text, '{"not":"an array"}'::jsonb, 'Must roll back'::text);
    EXCEPTION WHEN SQLSTATE '22023' THEN denied := true;
    END;
    IF NOT denied THEN RAISE EXCEPTION 'Malformed replacement input was accepted'; END IF;
    checks := checks + 1;
    EXECUTE 'RESET ROLE';
    SELECT jsonb_build_object(
      'p',(SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.playlists p),
      't',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.tracks t)) INTO after_data;
    IF after_data IS DISTINCT FROM before_data THEN
      RAISE EXCEPTION 'Rejected RPC or failed replacement left partial changes';
    END IF;
    checks := checks + 1;
  END LOOP;
  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'PASS PostgreSQL 17: % role-flow assertions; no synthetic token values printed', checks;
END;
$current_frontend_flow$;

ROLLBACK;

-- A nonempty sentinel remains only in this disposable database so the runner can
-- prove rejected schema replay preserves data. No actual application data exists.
INSERT INTO public.playlists(slug, edit_token, title)
  VALUES ('synthetic-replay-sentinel', 'SYNTHETIC-ONLY-REPLAY-CAPABILITY', 'Replay must preserve this row');
\echo PASS PostgreSQL 17 SQL suite; legacy_defaults=:legacy_defaults
