import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

// Deliberately no database URL, filesystem persistence or pgcrypto registration.
// The recovered RPCs use PostgreSQL's built-in gen_random_uuid().
const setupPath = fileURLToPath(new URL('../v1/setup.sql', import.meta.url));
const resultPath = fileURLToPath(new URL('../test-results.json', import.meta.url));
const setup = await readFile(setupPath, 'utf8');
const sourceHash = createHash('sha256').update(setup).digest('hex');
console.log(`Setup SHA-256: ${sourceHash}`);
const roles = ['anon', 'authenticated', 'service_role'];
const databases = [];
const results = [];
const roleDDL = `CREATE ROLE anon NOLOGIN NOSUPERUSER NOBYPASSRLS;
  CREATE ROLE authenticated NOLOGIN NOSUPERUSER NOBYPASSRLS;
  CREATE ROLE service_role NOLOGIN NOSUPERUSER BYPASSRLS;`;

async function fresh({ createRoles = true } = {}) {
  const db = new PGlite(); databases.push(db);
  if (createRoles) await db.exec(roleDDL);
  return db;
}
async function check(name, action) {
  await action(); results.push({ name, passed: true }); console.log(`PASS ${name}`);
}
async function asRole(db, role, action) {
  assert(roles.includes(role)); await db.exec(`SET ROLE ${role}`);
  try { return await action(); } finally { await db.exec('RESET ROLE'); }
}
async function expectError(db, role, sql, params, code) {
  let failure;
  await asRole(db, role, async () => {
    try { await db.query(sql, params); } catch (error) { failure = error; }
  });
  assert(failure, 'Expected query to be rejected');
  if (code) assert.equal(failure.code, code);
}
async function snapshot(db) {
  // Only a digest is retained; generated synthetic edit tokens never enter output.
  const q = await db.query(`SELECT jsonb_build_object(
    'playlists',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY id),'[]') FROM public.playlists p),
    'tracks',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM public.tracks t)
  ) AS data`);
  return createHash('sha256').update(JSON.stringify(q.rows[0].data)).digest('hex');
}
async function getByToken(db, role, token) {
  const q = await asRole(db, role, () => db.query(
    'SELECT public.get_silent_radio_by_edit_token(p_edit_token => $1::text) AS data', [token]));
  return q.rows[0].data;
}
const tracks = [
  { title: 'Synthetic song A', artist: 'Synthetic artist', album: 'Fixture album', year: '2026', feeling: 'Synthetic memory A' },
  { title: 'Synthetic song B', artist: 'Synthetic artist', feeling: 'Synthetic memory B' },
];
const replacementTracks = [{ title: 'Replacement song', artist: 'Synthetic replacement artist', feeling: 'Replacement memory' }];
const extendedCreate = `SELECT * FROM public.create_silent_radio(
  p_title => $1::text, p_subtitle => $2::text, p_tracks => $3::jsonb, p_creator_name => $4::text)`;
const extendedUpdate = `SELECT * FROM public.update_silent_radio(
  p_edit_token => $1::text, p_title => $2::text, p_subtitle => $3::text, p_tracks => $4::jsonb, p_creator_name => $5::text)`;
const legacyCreate = `SELECT * FROM public.create_silent_radio($1::text, $2::text, $3::jsonb)`;
const legacyUpdate = `SELECT * FROM public.update_silent_radio($1::text, $2::text, $3::text, $4::jsonb)`;
let engineVersion;

try {
  const db = await fresh();
  engineVersion = (await db.query('SELECT version()')).rows[0].version;
  await check('fresh baseline has no automatic table grants', async () => {
    const q = await db.query(`SELECT count(*)::int n FROM pg_default_acl d, LATERAL aclexplode(d.defaclacl) a
      WHERE d.defaclobjtype='r' AND a.grantee IN ('anon'::regrole,'authenticated'::regrole,'service_role'::regrole)`);
    assert.equal(q.rows[0].n, 0);
  });
  await check('core UUID generator is available without pgcrypto', async () => {
    const q = await db.query(`SELECT to_regprocedure('pg_catalog.gen_random_uuid()') IS NOT NULL AS core_uuid,
      EXISTS(SELECT 1 FROM pg_extension WHERE extname='pgcrypto') AS crypto`);
    assert.deepEqual(q.rows, [{ core_uuid: true, crypto: false }]);
  });
  await db.exec(setup);
  await check('full setup succeeds without installing extra extensions', async () => {
    const q = await db.query("SELECT extname FROM pg_extension WHERE extname <> 'plpgsql'");
    assert.equal(q.rows.length, 0);
  });
  await check('two tables, five RPC signatures and one trigger are present', async () => {
    const q = await db.query(`SELECT
      (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r') AS tables,
      (SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('create_silent_radio','get_silent_radio_by_edit_token','update_silent_radio')) AS rpcs,
      (SELECT count(*)::int FROM pg_trigger WHERE tgrelid='public.playlists'::regclass AND NOT tgisinternal) AS triggers`);
    assert.deepEqual(q.rows, [{ tables: 2, rpcs: 5, triggers: 1 }]);
  });
  await check('five RPC definitions retain observed owner, definer mode and callable roles',async()=>{
    const q=await db.query(`SELECT p.oid::regprocedure::text AS signature, p.prosecdef,
      pg_get_userbyid(p.proowner) AS owner, p.proconfig
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname IN ('create_silent_radio','get_silent_radio_by_edit_token','update_silent_radio')`);
    assert.equal(q.rows.length,5);
    for(const fn of q.rows){
      assert.equal(fn.prosecdef,true);assert.equal(fn.owner,'postgres');assert.deepEqual(fn.proconfig,['search_path=public']);
      for(const role of roles){
        const acl=await db.query(`SELECT has_function_privilege($1,$2,'EXECUTE') AS allowed`,[role,fn.signature]);
        assert.equal(acl.rows[0].allowed,true);
      }
    }
  });
  await check('both tables enable RLS and no sequences are created', async () => {
    const q = await db.query(`SELECT relkind,relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind IN ('r','S')`);
    assert.equal(q.rows.length,2);assert(q.rows.every(r=>r.relkind==='r'&&r.relrowsecurity));
  });
  for (const role of ['anon', 'authenticated']) {
    let created;
    await check(`${role} current create RPC returns a new synthetic caller edit token`, async () => {
      const q = await asRole(db, role, () => db.query(extendedCreate,
        [`Fixture ${role}`, 'Synthetic subtitle', JSON.stringify(tracks), `Synthetic ${role}`]));
      assert.equal(q.rows.length, 1); created = q.rows[0];
      assert.equal(typeof created.slug, 'string'); assert(created.slug.length>0);
      assert.match(created.edit_token, /^[0-9a-f]{64}$/);
    });
    await check(`${role} valid edit token loads ordered tracks and creator`, async () => {
      const data = await getByToken(db, role, created.edit_token);
      assert.equal(data.slug, created.slug); assert.equal(data.edit_token, created.edit_token);
      assert.equal(data.creator_name, `Synthetic ${role}`);
      assert.deepEqual(data.tracks.map(t => t.title), tracks.map(t => t.title));
    });
    await check(`${role} exact frontend feed projection omits edit tokens`, async () => {
      const q = await asRole(db, role, () => db.query(`SELECT slug,title,creator_name,created_at
        FROM public.playlists ORDER BY created_at DESC LIMIT 20`));
      assert(q.rows.some(r=>r.slug===created.slug));
      assert(q.rows.every(r=>!Object.hasOwn(r,'edit_token')));
    });
    let playlistId;
    await check(`${role} exact frontend playlist and track projections succeed`, async () => {
      const q = await asRole(db, role, () => db.query(`SELECT id,slug,title,subtitle,creator_name
        FROM public.playlists WHERE slug=$1 LIMIT 1`,[created.slug]));
      assert.equal(q.rows.length,1);playlistId=q.rows[0].id;
      const t = await asRole(db, role, () => db.query(`SELECT title,artist,album,year,artwork_url,apple_url,spotify_url,youtube_url,feeling
        FROM public.tracks WHERE playlist_id=$1 ORDER BY position ASC`,[playlistId]));
      assert.deepEqual(t.rows.map(t=>t.title),tracks.map(t=>t.title));
    });
    for (const sql of ['SELECT edit_token FROM public.playlists','SELECT * FROM public.playlists']) {
      await check(`${role} denied ${sql.includes('*')?'wildcard':'edit-token'} playlist read`,()=>expectError(db,role,sql,[],'42501'));
    }
    for(const table of ['playlists','tracks']) {
      for(const [operation,sql] of [
        ['INSERT',`INSERT INTO public.${table} DEFAULT VALUES`],
        ['UPDATE',`UPDATE public.${table} SET title=title`],
        ['DELETE',`DELETE FROM public.${table}`],
      ])await check(`${role} direct ${operation} on ${table} denied`,()=>expectError(db,role,sql,[],'42501'));
    }
    await check(`${role} current update RPC changes playlist and atomically replaces tracks`, async () => {
      const beforeStamp=(await db.query(`SELECT updated_at::text AS stamp FROM public.playlists WHERE id=$1`,[playlistId])).rows[0].stamp;
      const q = await asRole(db,role,()=>db.query(extendedUpdate,
        [created.edit_token,`Updated ${role}`,'Updated subtitle',JSON.stringify(replacementTracks),`Updated creator ${role}`]));
      assert.deepEqual(q.rows,[{slug:created.slug}]);
      const data=await getByToken(db,role,created.edit_token);
      assert.equal(data.title,`Updated ${role}`);assert.equal(data.creator_name,`Updated creator ${role}`);
      assert.deepEqual(data.tracks.map(t=>t.title),['Replacement song']);
      const stamp=await db.query(`SELECT updated_at>$2::timestamptz AS touched FROM public.playlists WHERE id=$1`,[playlistId,beforeStamp]);
      assert.equal(stamp.rows[0].touched,true);
    });
    await check(`${role} bogus get token is rejected without changing any data`,async()=>{
      const before=await snapshot(db);
      await expectError(db,role,'SELECT public.get_silent_radio_by_edit_token($1::text)',['SYNTHETIC-INVALID-token'],'P0001');
      assert.equal(await snapshot(db),before);
    });
    await check(`${role} bogus update token is rejected without changing any data`,async()=>{
      const before=await snapshot(db);
      await expectError(db,role,extendedUpdate,['SYNTHETIC-INVALID-token','Invalid mutation','Invalid',JSON.stringify([]),'Invalid'],'P0001');
      assert.equal(await snapshot(db),before);
    });
    await check(`${role} malformed replacement rolls back playlist update and track deletion`,async()=>{
      const before=await snapshot(db);
      await expectError(db,role,extendedUpdate,[created.edit_token,'Must roll back','Must roll back',JSON.stringify({not:'an array'}),'Must roll back'],'22023');
      assert.equal(await snapshot(db),before);
    });
    await check(`${role} inherited shorter create overload ambiguity remains 42725 with no data changes`,async()=>{
      const before=await snapshot(db);
      await expectError(db,role,legacyCreate,[`Legacy ${role}`,'Legacy subtitle',JSON.stringify(tracks)],'42725');
      assert.equal(await snapshot(db),before);
    });
    await check(`${role} inherited shorter update overload ambiguity remains 42725 with no data changes`,async()=>{
      const before=await snapshot(db);
      await expectError(db,role,legacyUpdate,[created.edit_token,`Legacy updated ${role}`,'Legacy updated subtitle',JSON.stringify(replacementTracks)],'42725');
      assert.equal(await snapshot(db),before);
    });
  }
  await db.exec(`INSERT INTO public.playlists(id,slug,edit_token,published)
    VALUES('00000000-0000-0000-0000-000000000001','synthetic-hidden-draft','SYNTHETIC-ONLY-DRAFT',false);
    INSERT INTO public.tracks(playlist_id,title,artist)
    VALUES('00000000-0000-0000-0000-000000000001','Hidden draft track','Synthetic artist');`);
  for(const role of ['anon','authenticated']) {
    await check(`${role} draft playlists and draft-linked tracks remain hidden`,async()=>{
      const p=await asRole(db,role,()=>db.query(`SELECT slug FROM public.playlists WHERE slug='synthetic-hidden-draft'`));
      const t=await asRole(db,role,()=>db.query(`SELECT title FROM public.tracks WHERE title='Hidden draft track'`));
      assert.equal(p.rows.length,0);assert.equal(t.rows.length,0);
    });
    await check(`${role} valid draft token remains usable by its holder`,async()=>{
      const data=await getByToken(db,role,'SYNTHETIC-ONLY-DRAFT');
      assert.equal(data.slug,'synthetic-hidden-draft');assert.deepEqual(data.tracks.map(t=>t.title),['Hidden draft track']);
    });
  }
  await check('schema replay refuses existing objects without changing data',async()=>{
    const before=await snapshot(db);let failure;
    try{await db.exec(setup);}catch(error){failure=error;}
    assert(failure,'Replay must be refused');await db.exec('ROLLBACK');
    assert.equal(await snapshot(db),before);
  });
  await check('missing API roles fails before creating application objects',async()=>{
    const missing=await fresh({createRoles:false});let failure;
    try{await missing.exec(setup);}catch(error){failure=error;}
    assert(failure,'Missing required roles must fail');await missing.exec('ROLLBACK');
    const q=await missing.query(`SELECT to_regclass('public.playlists') AS playlists,to_regclass('public.tracks') AS tracks`);
    assert.deepEqual(q.rows,[{playlists:null,tracks:null}]);
  });
  await check('non-owner provisioning is refused before any application object is created',async()=>{
    const nonOwner=await fresh();await nonOwner.exec('CREATE ROLE test_installer NOLOGIN; SET ROLE test_installer');
    let failure;try{await nonOwner.exec(setup);}catch(error){failure=error;}
    assert.equal(failure?.code,'P0001');await nonOwner.exec('ROLLBACK; RESET ROLE');
    assert.equal((await nonOwner.query("SELECT to_regclass('public.playlists') AS playlists")).rows[0].playlists,null);
  });
  await check('pre-existing target table is preserved and setup aborts atomically',async()=>{
    const existing=await fresh();await existing.exec('CREATE TABLE public.playlists(sentinel integer); INSERT INTO public.playlists VALUES(42)');
    let failure;try{await existing.exec(setup);}catch(error){failure=error;}
    assert(failure);await existing.exec('ROLLBACK');
    assert.deepEqual((await existing.query('SELECT sentinel FROM public.playlists')).rows,[{sentinel:42}]);
    assert.equal((await existing.query("SELECT to_regclass('public.tracks') AS tracks")).rows[0].tracks,null);
  });
  await check('pre-existing target function is preserved and setup aborts atomically',async()=>{
    const existing=await fresh();await existing.exec(`CREATE FUNCTION public.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$`);
    const before=(await existing.query("SELECT pg_get_functiondef('public.set_updated_at()'::regprocedure) AS ddl")).rows[0].ddl;
    let failure;try{await existing.exec(setup);}catch(error){failure=error;}
    assert(failure);await existing.exec('ROLLBACK');
    assert.equal((await existing.query("SELECT pg_get_functiondef('public.set_updated_at()'::regprocedure) AS ddl")).rows[0].ddl,before);
    assert.equal((await existing.query("SELECT to_regclass('public.playlists') AS playlists")).rows[0].playlists,null);
  });
  const legacyDefaults=await fresh();
  await legacyDefaults.exec(`ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON TABLES TO anon,authenticated,service_role;`);
  const defaultSnapshot=(await legacyDefaults.query('SELECT * FROM pg_default_acl')).rows;
  await legacyDefaults.exec(setup);
  await check('setup preserves preseeded legacy default privileges themselves',async()=>{
    assert.deepEqual((await legacyDefaults.query('SELECT * FROM pg_default_acl')).rows,defaultSnapshot);
  });
  await check('new objects have exact limited permissions even under legacy defaults',async()=>{
    for(const role of roles)for(const table of ['playlists','tracks'])for(const privilege of ['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN']){
      const q=await legacyDefaults.query('SELECT has_table_privilege($1,$2,$3) AS allowed',[role,`public.${table}`,privilege]);
      assert.equal(q.rows[0].allowed,role!=='service_role'&&table==='tracks'&&privilege==='SELECT',`${role} ${table} ${privilege}`);
    }
    for(const role of roles)for(const column of ['id','slug','edit_token','title','subtitle','published','created_at','updated_at','creator_name']){
      const q=await legacyDefaults.query(`SELECT has_column_privilege($1,'public.playlists',$2,'SELECT') AS allowed`,[role,column]);
      assert.equal(q.rows[0].allowed,role!=='service_role'&&!['edit_token','updated_at'].includes(column),`${role} SELECT ${column}`);
    }
  });
  for(const role of ['anon','authenticated']){
    await check(`${role} current RPC create/get/update work under legacy defaults`,async()=>{
      const create=await asRole(legacyDefaults,role,()=>legacyDefaults.query(extendedCreate,
        [`Legacy defaults ${role}`,'Fixture',JSON.stringify(tracks),'Fixture creator']));
      const token=create.rows[0].edit_token;
      const before=await getByToken(legacyDefaults,role,token);assert.equal(before.tracks.length,2);
      await asRole(legacyDefaults,role,()=>legacyDefaults.query(extendedUpdate,
        [token,'Updated legacy defaults','Updated',JSON.stringify(replacementTracks),'Updated creator']));
      const after=await getByToken(legacyDefaults,role,token);assert.equal(after.title,'Updated legacy defaults');assert.equal(after.tracks.length,1);
    });
    await check(`${role} direct token read and INSERT stay denied under legacy defaults`,async()=>{
      await expectError(legacyDefaults,role,'SELECT edit_token FROM public.playlists',[],'42501');
      await expectError(legacyDefaults,role,'INSERT INTO public.playlists DEFAULT VALUES',[],'42501');
    });
  }
  await check('unexpected inherited default SELECT aborts all provisioning changes',async()=>{
    const inherited=await fresh();await inherited.exec(`CREATE ROLE unexpected_reader NOLOGIN;
      GRANT unexpected_reader TO anon;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO unexpected_reader;`);
    const before=(await inherited.query('SELECT * FROM pg_default_acl')).rows;
    let failure;try{await inherited.exec(setup);}catch(error){failure=error;}
    assert.equal(failure?.code,'P0001');await inherited.exec('ROLLBACK');
    const q=await inherited.query(`SELECT to_regclass('public.playlists') AS playlists,
      to_regclass('public.tracks') AS tracks,
      to_regprocedure('public.get_silent_radio_by_edit_token(text)') AS rpc`);
    assert.deepEqual(q.rows,[{playlists:null,tracks:null,rpc:null}]);
    assert.deepEqual((await inherited.query('SELECT * FROM pg_default_acl')).rows,before);
  });
  const report={testedAt:new Date().toISOString(),engine:'@electric-sql/pglite 0.5.11',engineVersion,setupPath,setupSha256:sourceHash,
    passed:results.length,failed:0,results,limitations:[
      'Only disposable in-memory PostgreSQL databases and synthetic data were used. No network database, real credentials, or application records.',
      'SQL tests exercise exact provisioning DDL and RPC bodies but not PostgREST HTTP argument resolution, GraphQL, JWT/auth, browser state or hosting.',
      'Known inherited limitation: shorter create/update SQL argument shapes return 42725 because newer overloads have default parameters. Regression checks document this; they do not claim legacy calls work. Exact function definitions remain unchanged.',
      'The current frontend sends creator_name explicitly; PostgREST dispatch for older payload shapes remains unverified.',
      'This is fresh setup verification, not a production migration or permission to run provisioning against an existing project.',
    ]};
  await writeFile(resultPath,JSON.stringify(report,null,2)+'\n');
  console.log(`\n${results.length} checks passed; 0 failed.`);
}catch(error){
  await writeFile(resultPath,JSON.stringify({setupPath,setupSha256:sourceHash,passed:results.length,failed:1,results,error:{message:error.message,code:error.code}},null,2)+'\n');
  console.error(`FAIL ${error.code ?? 'assertion'}: ${error.message}`);
  process.exitCode=1;
}finally{for(const db of databases)await db.close();}
