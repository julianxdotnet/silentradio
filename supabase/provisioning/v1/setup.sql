-- Silent Radio v1: NEW disposable/approved fresh application namespace only.
-- Recovered structure and function bodies; intended explicit table access.
-- NOT the pending production safe-column patch. Never use as a production reset.
-- Refuses existing objects before any DDL/ACL changes. No seeds or credentials.
BEGIN;
SET LOCAL search_path = public;

DO $fresh_target$
DECLARE role_name text;
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'Fresh setup requires the postgres owner role';
  END IF;
  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
      RAISE EXCEPTION 'Required platform role is missing: %', role_name;
    END IF;
  END LOOP;
  IF to_regprocedure('pg_catalog.gen_random_uuid()') IS NULL THEN
    RAISE EXCEPTION 'Core gen_random_uuid() is required';
  END IF;
  IF to_regclass('public.playlists') IS NOT NULL
     OR to_regclass('public.tracks') IS NOT NULL
     OR EXISTS (
       SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname IN
         ('create_silent_radio','get_silent_radio_by_edit_token',
          'update_silent_radio','set_updated_at')
     ) THEN
    RAISE EXCEPTION 'Fresh setup refused: Silent Radio objects already exist';
  END IF;
END;
$fresh_target$;


-- Catalog owner: postgres; all columns use default collation where applicable.
CREATE TABLE "public"."playlists" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "slug" text NOT NULL,
  "edit_token" text NOT NULL,
  "title" text DEFAULT 'Untitled Silent Radio'::text NOT NULL,
  "subtitle" text DEFAULT 'A few songs, and the memories they unlock.'::text NOT NULL,
  "published" boolean DEFAULT true NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "creator_name" text DEFAULT 'Anonymous listener'::text NOT NULL,
  CONSTRAINT "playlists_edit_token_key" UNIQUE (edit_token),
  CONSTRAINT "playlists_pkey" PRIMARY KEY (id),
  CONSTRAINT "playlists_slug_key" UNIQUE (slug)
);

-- Catalog owner: postgres; all columns use default collation where applicable.
CREATE TABLE "public"."tracks" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "playlist_id" uuid NOT NULL,
  "position" integer DEFAULT 0 NOT NULL,
  "title" text NOT NULL,
  "artist" text NOT NULL,
  "album" text,
  "year" text,
  "artwork_url" text,
  "apple_url" text,
  "spotify_url" text,
  "youtube_url" text,
  "feeling" text DEFAULT ''::text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "tracks_pkey" PRIMARY KEY (id),
  CONSTRAINT "tracks_playlist_id_fkey" FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
);

CREATE INDEX tracks_playlist_position_idx ON public.tracks USING btree (playlist_id, "position");

CREATE OR REPLACE FUNCTION public.create_silent_radio(p_title text, p_subtitle text, p_tracks jsonb)
 RETURNS TABLE(slug text, edit_token text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_playlist_id uuid;
  v_slug text;
  v_edit_token text;
  v_track jsonb;
  v_position int := 0;
begin
  v_slug := lower(regexp_replace(coalesce(nullif(p_title, ''), 'silent-radio'), '[^a-zA-Z0-9]+', '-', 'g'));
  v_slug := trim(both '-' from v_slug) || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_edit_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  insert into playlists(slug, edit_token, title, subtitle)
  values (v_slug, v_edit_token, coalesce(nullif(p_title, ''), 'Untitled Silent Radio'), coalesce(p_subtitle, ''))
  returning id into v_playlist_id;

  for v_track in select * from jsonb_array_elements(coalesce(p_tracks, '[]'::jsonb)) loop
    insert into tracks(playlist_id, position, title, artist, album, year, artwork_url, apple_url, spotify_url, youtube_url, feeling)
    values (
      v_playlist_id,
      v_position,
      coalesce(v_track->>'title', 'Untitled track'),
      coalesce(v_track->>'artist', 'Unknown artist'),
      v_track->>'album',
      v_track->>'year',
      v_track->>'artwork_url',
      v_track->>'apple_url',
      v_track->>'spotify_url',
      v_track->>'youtube_url',
      coalesce(v_track->>'feeling', '')
    );
    v_position := v_position + 1;
  end loop;

  return query select v_slug, v_edit_token;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_silent_radio(p_title text, p_subtitle text, p_tracks jsonb, p_creator_name text DEFAULT 'Anonymous listener'::text)
 RETURNS TABLE(slug text, edit_token text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_playlist_id uuid;
  v_slug text;
  v_edit_token text;
  v_track jsonb;
  v_position int := 0;
begin
  v_slug := lower(regexp_replace(coalesce(nullif(p_title, ''), 'silent-radio'), '[^a-zA-Z0-9]+', '-', 'g'));
  v_slug := trim(both '-' from v_slug) || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  v_edit_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  insert into playlists(slug, edit_token, title, subtitle, creator_name)
  values (v_slug, v_edit_token, coalesce(nullif(p_title, ''), 'Untitled Silent Radio'), coalesce(p_subtitle, ''), coalesce(nullif(p_creator_name, ''), 'Anonymous listener'))
  returning id into v_playlist_id;

  for v_track in select * from jsonb_array_elements(coalesce(p_tracks, '[]'::jsonb)) loop
    insert into tracks(playlist_id, position, title, artist, album, year, artwork_url, apple_url, spotify_url, youtube_url, feeling)
    values (v_playlist_id, v_position, coalesce(v_track->>'title', 'Untitled track'), coalesce(v_track->>'artist', 'Unknown artist'), v_track->>'album', v_track->>'year', v_track->>'artwork_url', v_track->>'apple_url', v_track->>'spotify_url', v_track->>'youtube_url', coalesce(v_track->>'feeling', ''));
    v_position := v_position + 1;
  end loop;

  return query select v_slug, v_edit_token;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_silent_radio_by_edit_token(p_edit_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_playlist playlists%rowtype;
  v_tracks jsonb;
begin
  select * into v_playlist from playlists where edit_token = p_edit_token;
  if v_playlist.id is null then raise exception 'Invalid edit token'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('title', title, 'artist', artist, 'album', album, 'year', year, 'artwork_url', artwork_url, 'apple_url', apple_url, 'spotify_url', spotify_url, 'youtube_url', youtube_url, 'feeling', feeling) order by position), '[]'::jsonb)
  into v_tracks from tracks where playlist_id = v_playlist.id;
  return jsonb_build_object('slug', v_playlist.slug, 'edit_token', v_playlist.edit_token, 'title', v_playlist.title, 'subtitle', v_playlist.subtitle, 'creator_name', v_playlist.creator_name, 'tracks', v_tracks);
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_silent_radio(p_edit_token text, p_title text, p_subtitle text, p_tracks jsonb)
 RETURNS TABLE(slug text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_playlist_id uuid;
  v_slug text;
  v_track jsonb;
  v_position int := 0;
begin
  select id, playlists.slug into v_playlist_id, v_slug
  from playlists
  where edit_token = p_edit_token;

  if v_playlist_id is null then
    raise exception 'Invalid edit token';
  end if;

  update playlists
  set title = coalesce(nullif(p_title, ''), title), subtitle = coalesce(p_subtitle, subtitle)
  where id = v_playlist_id;

  delete from tracks where playlist_id = v_playlist_id;

  for v_track in select * from jsonb_array_elements(coalesce(p_tracks, '[]'::jsonb)) loop
    insert into tracks(playlist_id, position, title, artist, album, year, artwork_url, apple_url, spotify_url, youtube_url, feeling)
    values (
      v_playlist_id,
      v_position,
      coalesce(v_track->>'title', 'Untitled track'),
      coalesce(v_track->>'artist', 'Unknown artist'),
      v_track->>'album',
      v_track->>'year',
      v_track->>'artwork_url',
      v_track->>'apple_url',
      v_track->>'spotify_url',
      v_track->>'youtube_url',
      coalesce(v_track->>'feeling', '')
    );
    v_position := v_position + 1;
  end loop;

  return query select v_slug;
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_silent_radio(p_edit_token text, p_title text, p_subtitle text, p_tracks jsonb, p_creator_name text DEFAULT NULL::text)
 RETURNS TABLE(slug text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_playlist_id uuid;
  v_slug text;
  v_track jsonb;
  v_position int := 0;
begin
  select id, playlists.slug into v_playlist_id, v_slug from playlists where edit_token = p_edit_token;
  if v_playlist_id is null then raise exception 'Invalid edit token'; end if;

  update playlists
  set title = coalesce(nullif(p_title, ''), title), subtitle = coalesce(p_subtitle, subtitle), creator_name = coalesce(nullif(p_creator_name, ''), creator_name)
  where id = v_playlist_id;

  delete from tracks where playlist_id = v_playlist_id;
  for v_track in select * from jsonb_array_elements(coalesce(p_tracks, '[]'::jsonb)) loop
    insert into tracks(playlist_id, position, title, artist, album, year, artwork_url, apple_url, spotify_url, youtube_url, feeling)
    values (v_playlist_id, v_position, coalesce(v_track->>'title', 'Untitled track'), coalesce(v_track->>'artist', 'Unknown artist'), v_track->>'album', v_track->>'year', v_track->>'artwork_url', v_track->>'apple_url', v_track->>'spotify_url', v_track->>'youtube_url', coalesce(v_track->>'feeling', ''));
    v_position := v_position + 1;
  end loop;
  return query select v_slug;
end;
$function$;

CREATE TRIGGER playlists_set_updated_at BEFORE UPDATE ON public.playlists FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE "public"."playlists" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "public can create playlists" ON "public"."playlists" AS PERMISSIVE FOR INSERT TO "public" WITH CHECK (true);

CREATE POLICY "public can read published playlists" ON "public"."playlists" AS PERMISSIVE FOR SELECT TO "public" USING ((published = true));

CREATE POLICY "public can update playlist drafts by direct token disabled" ON "public"."playlists" AS PERMISSIVE FOR UPDATE TO "public" USING (false) WITH CHECK (false);

ALTER TABLE "public"."tracks" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "direct track deletes disabled" ON "public"."tracks" AS PERMISSIVE FOR DELETE TO "public" USING (false);

CREATE POLICY "direct track updates disabled" ON "public"."tracks" AS PERMISSIVE FOR UPDATE TO "public" USING (false) WITH CHECK (false);

CREATE POLICY "direct track writes disabled" ON "public"."tracks" AS PERMISSIVE FOR INSERT TO "public" WITH CHECK (false);

CREATE POLICY "public can read tracks for published playlists" ON "public"."tracks" AS PERMISSIVE FOR SELECT TO "public" USING ((EXISTS ( SELECT 1
   FROM playlists p
  WHERE ((p.id = tracks.playlist_id) AND (p.published = true)))));


-- Per-object removal of any platform legacy auto-grants on these NEW tables.
-- No existing tables or schema-wide default privileges are changed.
REVOKE ALL PRIVILEGES ON TABLE public.playlists FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL PRIVILEGES ON TABLE public.tracks FROM PUBLIC, anon, authenticated, service_role;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT (id, slug, title, subtitle, creator_name, created_at, published)
  ON TABLE public.playlists TO anon;
GRANT SELECT (id, slug, title, subtitle, creator_name, created_at, published)
  ON TABLE public.playlists TO authenticated;
GRANT SELECT ON TABLE public.tracks TO anon;
GRANT SELECT ON TABLE public.tracks TO authenticated;

-- Preserve the observed current callable-function contract. These are deliberate
-- existing capability endpoints, not newly exposed generic functions.
GRANT EXECUTE ON FUNCTION public.create_silent_radio(text,text,jsonb)
  TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_silent_radio(text,text,jsonb,text)
  TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_silent_radio_by_edit_token(text)
  TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_silent_radio(text,text,text,jsonb)
  TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_silent_radio(text,text,text,jsonb,text)
  TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_updated_at()
  TO PUBLIC, anon, authenticated, service_role;

-- Abort instead of silently accepting inherited/default permissions that defeat
-- the intended fresh-table contract. The entire setup rolls back on failure.
DO $verify_fresh_access$
DECLARE role_name text; table_name text; operation text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF has_column_privilege(role_name, 'public.playlists', 'edit_token', 'SELECT') THEN
      RAISE EXCEPTION 'Unexpected direct edit_token SELECT for %', role_name;
    END IF;
    FOREACH table_name IN ARRAY ARRAY['public.playlists', 'public.tracks'] LOOP
      FOREACH operation IN ARRAY ARRAY['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'] LOOP
        IF has_table_privilege(role_name, table_name, operation) THEN
          RAISE EXCEPTION 'Unexpected direct % on % for %', operation, table_name, role_name;
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  IF has_any_column_privilege('service_role', 'public.playlists', 'SELECT')
     OR has_any_column_privilege('service_role', 'public.tracks', 'SELECT') THEN
    RAISE EXCEPTION 'Unexpected service_role table reader; review its actual consumer before granting';
  END IF;
END;
$verify_fresh_access$;
COMMIT;
