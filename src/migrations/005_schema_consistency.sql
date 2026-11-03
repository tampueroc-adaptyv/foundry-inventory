\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
SET LOCAL lock_timeout='5s';
SELECT pg_advisory_xact_lock(741903);

DO $$ DECLARE n text; signature text; body text; expected integer; actual integer; BEGIN
 IF current_setting('server_version_num')::integer<180000 THEN
 RAISE EXCEPTION 'PostgreSQL 18+ required for native uuidv7()';
 END IF;
 FOREACH n IN ARRAY ARRAY['material','location','container','container_content','task','task_execution','task_execution_output','material_movement','material_posting','observation','assessment'] LOOP
 EXECUTE format('ALTER TABLE api.%I ALTER COLUMN id SET DEFAULT pg_catalog.uuidv7()',n);
 END LOOP;
 -- Keep historical migrations and existing records intact. Replace the six
 -- allocations in the retained handlers; also support the prior PG17 helper.
 -- CREATE OR REPLACE preserves function OIDs, ACLs and signatures.
 FOREACH signature IN ARRAY ARRAY['api.accept(uuid,text,text,jsonb)','api.inventory_accept(uuid,text,text,jsonb)'] LOOP
 body:=pg_get_functiondef(signature::regprocedure);
 body:=replace(replace(body,'gen_random_uuid()','pg_catalog.uuidv7()'),'api.uuid_v7()','pg_catalog.uuidv7()');
 actual:=(length(body)-length(replace(body,'pg_catalog.uuidv7()','')))/length('pg_catalog.uuidv7()');
 expected:=CASE WHEN signature='api.accept(uuid,text,text,jsonb)' THEN 1 ELSE 5 END;
 IF actual<>expected THEN RAISE EXCEPTION 'Unexpected UUID generation sites in %: expected %, got %',signature,expected,actual; END IF;
 EXECUTE body;
 END LOOP;
 FOREACH n IN ARRAY ARRAY['material_spec_catalog','container_spec_catalog','location_spec_catalog','task_spec_catalog','observation_specification_catalog','assessment_specification_catalog'] LOOP
 EXECUTE format('COMMENT ON COLUMN api.%I.published_at IS %L',n,'Actual specification publication instant (timestamptz); not a planned publication time.');
 END LOOP;
END $$;
-- Remove the old implementation when upgrading a populated PG17 dump. No
-- CASCADE: any unexpected dependency must fail rather than drop domain objects.
DROP FUNCTION IF EXISTS api.uuid_v7();
DROP FUNCTION IF EXISTS api.uuid_v7_from_parts(bigint,uuid);
COMMENT ON COLUMN api.task_execution_output.accepted_at IS 'Actual server acceptance instant; distinct from external occurrence and domain effective time. Never inferred from an identifier.';
COMMENT ON COLUMN api.container.effective_at IS 'Prospective placement validity boundary, not necessarily external physical occurrence time; sequence disambiguates equal boundaries.';
COMMENT ON COLUMN api.material_movement.effective_at IS 'Accounting effective instant; distinct from physical occurrence and output acceptance time.';
COMMENT ON COLUMN api.container_content.expires_at IS 'Expiration-policy cutoff/deadline, not an observed expiration event. Deliberately not named expired_at. Missing cutoff is not evidence of an expiration event.';
NOTIFY pgrst,'reload schema';
COMMIT;
