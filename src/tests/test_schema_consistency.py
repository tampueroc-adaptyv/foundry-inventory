"""Native UUIDv7 tests, schema inventory and a populated 004→005 upgrade.
The upgrade uses a disposable database on the same real PostgreSQL 18 server.
It does not replay old migrations against the live test database or rewrite IDs.
"""
import concurrent.futures
import pathlib
import unittest
import uuid

import psycopg
from psycopg import sql as identifiers
from psycopg.conninfo import make_conninfo
from psycopg.types.json import Jsonb

from test_modelj import DSN, db, fid, sql

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTITY_TABLES = ['material','location','container','container_content','task','task_execution',
                 'task_execution_output','material_movement','material_posting','observation','assessment']


def apply(c, script):
    # psql's sole metacommand is a runner option, not SQL.
    script = '\n'.join(line for line in script.splitlines() if not line.startswith('\\set '))
    cur = c.execute(script)
    while cur.nextset():
        pass


def snapshot(c):
    tables = c.execute("SELECT tablename FROM pg_tables WHERE schemaname='api' ORDER BY tablename").fetchall()
    return {n: c.execute(identifiers.SQL('SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),\'[]\') FROM api.{} r').format(identifiers.Identifier(n))).fetchone()[0]
            for (n,) in tables}


class SchemaConsistency(unittest.TestCase):
    def test_01_pg18_native_uuidv7(self):
        self.assertEqual(sql("SELECT current_setting('server_version_num')::int/10000",role=None),18)
        result = sql('SELECT pg_catalog.uuidv7()',role=None)
        self.assertEqual(result.version,7)
        self.assertEqual(result.variant,uuid.RFC_4122)
        self.assertEqual(sql('SELECT pg_catalog.uuid_extract_version(%s)',[result],role=None),7)
        # Native extraction agrees with an independent decode of the 48-bit field.
        ms = sql('SELECT floor(extract(epoch FROM pg_catalog.uuid_extract_timestamp(%s))*1000)::bigint',[result],role=None)
        self.assertEqual(ms,int(result.hex[:12],16))

    def test_02_random_sample_unique_and_wall_clock_bound(self):
        with db(None) as c:
            c.execute("SET LOCAL TIME ZONE 'Pacific/Auckland'")
            start = c.execute('SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint').fetchone()[0]
            values = [r[0] for r in c.execute('SELECT pg_catalog.uuidv7() FROM generate_series(1,10000)')]
            end = c.execute('SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint').fetchone()[0]
        self.assertEqual(len(values),len(set(values)))
        for value in values:
            self.assertEqual(value.version,7)
            self.assertEqual(value.variant,uuid.RFC_4122)
            self.assertLessEqual(start,int(value.hex[:12],16))
            self.assertLessEqual(int(value.hex[:12],16),end)
        # Sampling checks native execution/layout/collisions, not RNG quality.

    def test_03_parallel_generation(self):
        def generate(_):
            with db(None) as c:
                return [r[0] for r in c.execute('SELECT pg_catalog.uuidv7() FROM generate_series(1,1000)')]
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            values = [v for group in pool.map(generate,range(4)) for v in group]
        self.assertEqual(len(values),4000)
        self.assertEqual(len(set(values)),4000)
        self.assertTrue(all(v.version==7 for v in values))

    def test_04_all_defaults_handlers_and_no_custom_generator(self):
        with db(None) as c:
            for table in ENTITY_TABLES:
                default = c.execute("SELECT column_default FROM information_schema.columns WHERE table_schema='api' AND table_name=%s AND column_name='id'",[table]).fetchone()[0]
                self.assertIn(default,('uuidv7()','pg_catalog.uuidv7()'))
            for name,count in [('api.accept(uuid,text,text,jsonb)',1),('api.inventory_accept(uuid,text,text,jsonb)',5)]:
                body = c.execute('SELECT pg_get_functiondef(%s::regprocedure)',[name]).fetchone()[0]
                self.assertNotIn('gen_random_uuid()',body)
                self.assertNotIn('api.uuid_v7()',body)
                self.assertEqual(body.count('pg_catalog.uuidv7()'),count)
            self.assertIsNone(c.execute("SELECT to_regprocedure('api.uuid_v7()')").fetchone()[0])
            self.assertIsNone(c.execute("SELECT to_regprocedure('api.uuid_v7_from_parts(bigint,uuid)')").fetchone()[0])
        # The built-in utility grants no table mutation privileges.
        self.assertEqual(sql('SELECT pg_catalog.uuidv7()').version,7)

    def test_05_exact_timestamp_inventory_and_policy_exception(self):
        with db(None) as c:
            rows = c.execute("SELECT table_name,column_name,data_type FROM information_schema.columns WHERE table_schema='api' AND data_type IN ('timestamp with time zone','timestamp without time zone','date') ORDER BY table_name,column_name").fetchall()
            expected = {(t,'published_at') for t in ['material_spec_catalog','container_spec_catalog','location_spec_catalog','task_spec_catalog','observation_specification_catalog','assessment_specification_catalog']}
            expected |= {('container','effective_at'),('container_content','expires_at'),('material_movement','effective_at'),('task_execution_output','accepted_at')}
            self.assertEqual({(t,n) for t,n,_ in rows},expected)
            self.assertTrue(all(typ=='timestamp with time zone' for _,_,typ in rows))
            comment = c.execute("SELECT col_description('api.container_content'::regclass,attnum) FROM pg_attribute WHERE attrelid='api.container_content'::regclass AND attname='expires_at'").fetchone()[0]
            self.assertIn('not an observed expiration event',comment)
            self.assertIsNone(c.execute("SELECT column_default FROM information_schema.columns WHERE table_schema='api' AND table_name='container_content' AND column_name='expires_at'").fetchone()[0])

    def test_06_generated_persistent_rows_and_fixture_exceptions(self):
        with db(None) as c:
            # Every regular accepted output/projection/accounting ID created by the
            # existing HTTP/database suites must use v7; enrollment remains fixed.
            for table,condition in [
                ('material','created_output IS NOT NULL'),('container','created_output IS NOT NULL'),
                ('container_content','created_output IS NOT NULL'),('task',"request_key<>'enrollment'"),
                ('task_execution',"id NOT IN (api.fixture_id('aenrollment-execution'),api.fixture_id('benrollment-execution'))"),
                ('task_execution_output',"actor<>'administrator'"),('material_movement','true'),('material_posting','true'),
                ('observation',"spec_id='binding-dataset@1'"),('assessment',"spec_id<>'qc@1'")]:
                values = c.execute(identifiers.SQL('SELECT id FROM api.{} WHERE '+condition).format(identifiers.Identifier(table))).fetchall()
                self.assertTrue(all(v.version==7 for (v,) in values),table)
            self.assertEqual(c.execute("SELECT id FROM api.container_content WHERE tenant_id='a' AND id=api.fixture_id('aholding1')").fetchone()[0],fid('aholding1'))
            # Location has no public creation RPC: prove its default in a rolled-back owner setup.
            loc = c.execute("INSERT INTO api.location(tenant_id,spec_id,name,site,workcell) VALUES('a','lab@1','audit-only','site1','w1') RETURNING id").fetchone()[0]
            self.assertEqual(loc.version,7)
            c.rollback()

    def test_07_populated_upgrade_preserves_all_data_constraints_acl_and_retries(self):
        name = 'modelj_audit_' + uuid.uuid4().hex
        admin = psycopg.connect(DSN,autocommit=True)
        upgrade = None
        try:
            admin.execute(identifiers.SQL('CREATE DATABASE {}').format(identifiers.Identifier(name)))
            upgrade = psycopg.connect(make_conninfo(DSN,dbname=name),autocommit=True)
            first = (ROOT/'migrations/001_schema.sql').read_text()
            # Cluster roles already exist; the disposable DB gets the exact schema
            # body, not duplicate CREATE ROLE statements in the shared test cluster.
            first = 'BEGIN;\nCREATE SCHEMA api AUTHORIZATION modelj_owner;' + first.split('CREATE SCHEMA api AUTHORIZATION modelj_owner;',1)[1]
            apply(upgrade,first)
            for path in ['migrations/002_handlers.sql','migrations/003_integrity_and_rpc.sql','migrations/004_physical_inventory.sql','fixtures/seed.sql']:
                apply(upgrade,(ROOT/path).read_text())
            upgrade.execute('SET ROLE tenant_a')
            intent = {'supplier':'audit-supplier','delivery':'audit-delivery','line':'1','lot':'L1','coa':{'version':'coa-v1'},'holding':str(fid('aholding1')),'quantity':10,'unit':'uL'}
            out = upgrade.execute('SELECT api.register_receipt(%s,%s,%s,%s)',['audit-request',Jsonb(intent),'w1','verified audit receipt']).fetchone()[0]
            self.assertEqual(out.version,4)
            e,key,request = upgrade.execute('SELECT execution_id,request_key,request FROM api.task_execution_output WHERE id=%s',[out]).fetchone()
            # Exercise all explicit physical ID sites (including 384 fixed wells)
            # before upgrading, then verify their old IDs and manifests survive.
            reg = {'operation':'container','spec':'plate384@1','barcode':'audit-plate','location':str(fid('aloc1')),'position':'audit-position'}
            old_e = upgrade.execute('SELECT api.open_inventory_task(%s,%s,%s,%s)',['inventory-register@1','audit-plate',Jsonb(reg),'w1']).fetchone()[0]
            old_plate = upgrade.execute('SELECT api.inventory_accept(%s,%s,%s,%s)',[old_e,'register','register',Jsonb({'confirmed':True,'evidence':'verified enrollment'})]).fetchone()[0]
            self.assertEqual(old_plate.version,4)
            upgrade.execute('SET ROLE modelj_owner')
            before = snapshot(upgrade)
            constraints = upgrade.execute("SELECT oid,conname,contype,conrelid FROM pg_constraint WHERE connamespace='api'::regnamespace ORDER BY oid").fetchall()
            metadata_query = "SELECT oid,proowner,proacl::text,proconfig::text,prosecdef,provolatile FROM pg_proc WHERE oid IN ('api.accept(uuid,text,text,jsonb)'::regprocedure,'api.inventory_accept(uuid,text,text,jsonb)'::regprocedure) ORDER BY oid"
            metadata = upgrade.execute(metadata_query).fetchall()
            apply(upgrade,(ROOT/'migrations/005_schema_consistency.sql').read_text())
            self.assertEqual(snapshot(upgrade),before)
            self.assertEqual(upgrade.execute("SELECT oid,conname,contype,conrelid FROM pg_constraint WHERE connamespace='api'::regnamespace ORDER BY oid").fetchall(),constraints)
            self.assertEqual(upgrade.execute(metadata_query).fetchall(),metadata)
            upgrade.execute('SET ROLE tenant_a')
            retry = upgrade.execute('SELECT api.accept(%s,%s,%s,%s)',[e,key,request['port'],Jsonb(request['payload'])]).fetchone()[0]
            self.assertEqual(retry,out)
            self.assertEqual(retry.version,4)
            canonical = upgrade.execute('SELECT api.register_receipt(%s,%s,%s,%s)',['new-request-same-delivery',Jsonb(intent),'w1','another verified scan']).fetchone()[0]
            self.assertEqual(canonical,out)
            new_out = upgrade.execute('SELECT api.register_receipt(%s,%s,%s,%s)',['post-upgrade',Jsonb({**intent,'delivery':'new-delivery','holding':str(fid('aholding2'))}),'w1','verified new receipt']).fetchone()[0]
            self.assertEqual(new_out.version,7)
            reg['barcode']='new-audit-plate'
            reg['position']='new-audit-position'
            new_e = upgrade.execute('SELECT api.open_inventory_task(%s,%s,%s,%s)',['inventory-register@1','new-audit-plate',Jsonb(reg),'w1']).fetchone()[0]
            new_plate = upgrade.execute('SELECT api.inventory_accept(%s,%s,%s,%s)',[new_e,'register','register',Jsonb({'confirmed':True,'evidence':'verified enrollment'})]).fetchone()[0]
            self.assertEqual(new_plate.version,7)
            well_ids = upgrade.execute('SELECT id FROM api.container WHERE created_output=%s',[new_plate]).fetchall()
            self.assertEqual(len(well_ids),385)
            self.assertTrue(all(v.version==7 for (v,) in well_ids))
            self.assertTrue(upgrade.execute('SELECT api.verify_balances()').fetchone()[0])
        finally:
            if upgrade is not None:
                upgrade.close()
            admin.execute(identifiers.SQL('DROP DATABASE IF EXISTS {} WITH (FORCE)').format(identifiers.Identifier(name)))
            admin.close()


if __name__=='__main__':
    unittest.main(verbosity=2)
