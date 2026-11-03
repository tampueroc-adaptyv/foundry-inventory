\set ON_ERROR_STOP on
BEGIN;
CREATE ROLE modelj_owner NOLOGIN;
CREATE ROLE anonymous NOLOGIN;
CREATE ROLE tenant_a NOLOGIN;
CREATE ROLE tenant_b NOLOGIN;
CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD 'modelj';
GRANT anonymous, tenant_a, tenant_b TO authenticator;
CREATE SCHEMA api AUTHORIZATION modelj_owner;
SET ROLE modelj_owner;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
CREATE FUNCTION api.tenant() RETURNS text LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT CASE current_setting('role',true) WHEN 'tenant_a' THEN 'a' WHEN 'tenant_b' THEN 'b' ELSE NULL END
$$;
CREATE FUNCTION api.guard() RETURNS text LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog,api AS $$
BEGIN
 IF current_setting('transaction_isolation') <> 'read committed' THEN RAISE EXCEPTION 'READ COMMITTED required'; END IF;
 PERFORM set_config('lock_timeout','5s',true);
 PERFORM pg_advisory_xact_lock(741903);
 IF api.tenant() IS NULL THEN RAISE EXCEPTION 'authenticated tenant role required' USING ERRCODE='42501'; END IF;
 RETURN api.tenant();
END $$;
CREATE FUNCTION api.immutable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'immutable %',TG_TABLE_NAME; END $$;
DO $$ DECLARE n text; BEGIN
 FOREACH n IN ARRAY ARRAY['material_spec_catalog','container_spec_catalog','location_spec_catalog','task_spec_catalog','observation_specification_catalog','assessment_specification_catalog'] LOOP
 EXECUTE format('CREATE TABLE api.%I (tenant_id text NOT NULL, id text NOT NULL, version integer NOT NULL CHECK(version>0), handler text NOT NULL CHECK(handler=''v1''), definition jsonb NOT NULL CHECK(jsonb_typeof(definition)=''object''), published_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,id,version))',n);
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON api.%I FOR EACH ROW EXECUTE FUNCTION api.immutable()',n);
 END LOOP;
END $$;
CREATE TABLE api.material (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), spec_id text NOT NULL,
 label text NOT NULL, identity jsonb NOT NULL, created_output uuid,
 PRIMARY KEY(tenant_id,id), FOREIGN KEY(tenant_id,spec_id) REFERENCES api.material_spec_catalog(tenant_id,id));
CREATE TABLE api.location (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), spec_id text NOT NULL,
 name text NOT NULL, parent_id uuid, site text NOT NULL, workcell text,
 PRIMARY KEY(tenant_id,id), FOREIGN KEY(tenant_id,spec_id) REFERENCES api.location_spec_catalog(tenant_id,id),
 FOREIGN KEY(tenant_id,parent_id) REFERENCES api.location(tenant_id,id));
CREATE TABLE api.container (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), spec_id text NOT NULL,
 barcode text, parent_id uuid, location_id uuid, position text, fixed boolean NOT NULL DEFAULT false,
 placement_seq bigint NOT NULL DEFAULT 0, effective_at timestamptz NOT NULL DEFAULT clock_timestamp(), created_output uuid,
 PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,barcode), UNIQUE(tenant_id,parent_id,position),
 CHECK(num_nonnulls(parent_id,location_id)=1), CHECK(NOT fixed OR (parent_id IS NOT NULL AND position IS NOT NULL)),
 FOREIGN KEY(tenant_id,spec_id) REFERENCES api.container_spec_catalog(tenant_id,id),
 FOREIGN KEY(tenant_id,parent_id) REFERENCES api.container(tenant_id,id), FOREIGN KEY(tenant_id,location_id) REFERENCES api.location(tenant_id,id));
CREATE TABLE api.container_content (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), material_id uuid NOT NULL, container_id uuid NOT NULL,
 dimension text NOT NULL CHECK(dimension IN ('volume','mass','count')), closed boolean NOT NULL DEFAULT false,
 expires_at timestamptz, created_output uuid, close_output uuid,
 CHECK(closed=(close_output IS NOT NULL)),
 PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,id,material_id,dimension),
 FOREIGN KEY(tenant_id,material_id) REFERENCES api.material(tenant_id,id), FOREIGN KEY(tenant_id,container_id) REFERENCES api.container(tenant_id,id));
CREATE UNIQUE INDEX active_holding ON api.container_content(tenant_id,material_id,container_id) WHERE NOT closed;
CREATE TABLE api.task (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), spec_id text NOT NULL,
 request_key text NOT NULL, intent jsonb NOT NULL CHECK(jsonb_typeof(intent)='object'),
 supplier text, delivery text, source_line text,
 state text NOT NULL DEFAULT 'Pending' CHECK(state IN ('Pending','Completed','Canceled')),
 seq bigint NOT NULL DEFAULT 0, last_output uuid,
 PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,request_key), UNIQUE(tenant_id,supplier,delivery,source_line),
 FOREIGN KEY(tenant_id,spec_id) REFERENCES api.task_spec_catalog(tenant_id,id));
CREATE TABLE api.task_execution (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), task_id uuid NOT NULL, spec_id text NOT NULL,
 attempt integer NOT NULL, workcell text NOT NULL, state text NOT NULL DEFAULT 'Running' CHECK(state IN ('Running','Completed','Failed','Canceled')),
 terminal_output uuid, PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,task_id,attempt),
 CHECK((state='Running')=(terminal_output IS NULL)),
 FOREIGN KEY(tenant_id,task_id) REFERENCES api.task(tenant_id,id), FOREIGN KEY(tenant_id,spec_id) REFERENCES api.task_spec_catalog(tenant_id,id));
CREATE TABLE api.task_execution_output (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), execution_id uuid NOT NULL, spec_id text NOT NULL,
 request_key text NOT NULL, port text NOT NULL, request jsonb NOT NULL, payload jsonb NOT NULL,
 accepted_order bigint GENERATED ALWAYS AS IDENTITY, accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(), actor text NOT NULL,
 PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,execution_id,request_key),
 FOREIGN KEY(tenant_id,execution_id) REFERENCES api.task_execution(tenant_id,id), FOREIGN KEY(tenant_id,spec_id) REFERENCES api.task_spec_catalog(tenant_id,id));
ALTER TABLE api.task_execution ADD FOREIGN KEY(tenant_id,terminal_output) REFERENCES api.task_execution_output(tenant_id,id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE api.container_content ADD FOREIGN KEY(tenant_id,close_output) REFERENCES api.task_execution_output(tenant_id,id);
ALTER TABLE api.task ADD FOREIGN KEY(tenant_id,last_output) REFERENCES api.task_execution_output(tenant_id,id);
CREATE TABLE api.task_execution_output_entity (
 tenant_id text NOT NULL, output_id uuid NOT NULL, member text NOT NULL, role text NOT NULL,
 target_type text NOT NULL, target_id uuid NOT NULL, selector text NOT NULL DEFAULT '',
 PRIMARY KEY(tenant_id,output_id,member,role,target_type,target_id,selector),
 FOREIGN KEY(tenant_id,output_id) REFERENCES api.task_execution_output(tenant_id,id));
CREATE INDEX reverse_provenance ON api.task_execution_output_entity(tenant_id,target_type,target_id,selector);
CREATE UNIQUE INDEX settlement_claim ON api.task_execution_output_entity(tenant_id,target_id,selector) WHERE role='settlement';
CREATE UNIQUE INDEX command_claim ON api.task_execution_output_entity(tenant_id,target_id,selector) WHERE role='command';
CREATE TABLE api.material_movement (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), output_id uuid NOT NULL, member text NOT NULL,
 material_id uuid NOT NULL, dimension text NOT NULL, kind text NOT NULL, original_id uuid, effective_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,output_id,member), UNIQUE(tenant_id,id,material_id,dimension),
 FOREIGN KEY(tenant_id,output_id) REFERENCES api.task_execution_output(tenant_id,id), FOREIGN KEY(tenant_id,material_id) REFERENCES api.material(tenant_id,id),
 FOREIGN KEY(tenant_id,original_id) REFERENCES api.material_movement(tenant_id,id));
CREATE UNIQUE INDEX one_reversal ON api.material_movement(tenant_id,original_id) WHERE kind='reversal';
CREATE TABLE api.material_posting (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), movement_id uuid NOT NULL,
 material_id uuid NOT NULL, dimension text NOT NULL, holding_id uuid, account text,
 entered numeric NOT NULL CHECK(entered<>0), unit text NOT NULL, delta numeric NOT NULL CHECK(delta<>0),
 normalization text NOT NULL DEFAULT 'units@1' CHECK(normalization='units@1'), compensated_id uuid,
 PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,compensated_id), CHECK(num_nonnulls(holding_id,account)=1),
 CHECK(account IS NULL OR account IN ('receipt','production','consumption','disposal','discrepancy','correction')),
 FOREIGN KEY(tenant_id,movement_id,material_id,dimension) REFERENCES api.material_movement(tenant_id,id,material_id,dimension),
 FOREIGN KEY(tenant_id,holding_id,material_id,dimension) REFERENCES api.container_content(tenant_id,id,material_id,dimension),
 FOREIGN KEY(tenant_id,compensated_id) REFERENCES api.material_posting(tenant_id,id));
CREATE INDEX posting_holding ON api.material_posting(tenant_id,holding_id);
CREATE TABLE api.material_balance (
 tenant_id text NOT NULL, holding_id uuid NOT NULL, amount numeric NOT NULL DEFAULT 0, seq bigint NOT NULL DEFAULT 0,
 PRIMARY KEY(tenant_id,holding_id), FOREIGN KEY(tenant_id,holding_id) REFERENCES api.container_content(tenant_id,id));
CREATE FUNCTION api.initialize_balance() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,api AS $$
BEGIN INSERT INTO api.material_balance(tenant_id,holding_id) VALUES(NEW.tenant_id,NEW.id); RETURN NEW; END $$;
CREATE TRIGGER initialize_balance AFTER INSERT ON api.container_content FOR EACH ROW EXECUTE FUNCTION api.initialize_balance();
CREATE TABLE api.observation (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), output_id uuid NOT NULL, spec_id text NOT NULL,
 artifact jsonb NOT NULL, mapping jsonb NOT NULL, PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,output_id),
 FOREIGN KEY(tenant_id,output_id) REFERENCES api.task_execution_output(tenant_id,id), FOREIGN KEY(tenant_id,spec_id) REFERENCES api.observation_specification_catalog(tenant_id,id));
CREATE TABLE api.assessment (
 tenant_id text NOT NULL, id uuid NOT NULL DEFAULT gen_random_uuid(), output_id uuid NOT NULL, member text NOT NULL,
 spec_id text NOT NULL, subject_type text NOT NULL, subject_id uuid NOT NULL, subject jsonb NOT NULL,
 result jsonb NOT NULL, observation_id uuid NOT NULL, observation_member text NOT NULL, dependencies uuid[] NOT NULL DEFAULT '{}',
 PRIMARY KEY(tenant_id,id), UNIQUE(tenant_id,output_id,member),
 FOREIGN KEY(tenant_id,output_id) REFERENCES api.task_execution_output(tenant_id,id), FOREIGN KEY(tenant_id,spec_id) REFERENCES api.assessment_specification_catalog(tenant_id,id),
 FOREIGN KEY(tenant_id,observation_id) REFERENCES api.observation(tenant_id,id));
DO $$ DECLARE n text; BEGIN
 FOREACH n IN ARRAY ARRAY['material','location','container','container_content','task','task_execution','task_execution_output','task_execution_output_entity','material_movement','material_posting','material_balance','observation','assessment','material_spec_catalog','container_spec_catalog','location_spec_catalog','task_spec_catalog','observation_specification_catalog','assessment_specification_catalog'] LOOP
 EXECUTE format('ALTER TABLE api.%I ENABLE ROW LEVEL SECURITY',n);
 EXECUTE format('CREATE POLICY tenant_read ON api.%I FOR SELECT USING (tenant_id=api.tenant())',n);
 EXECUTE format('GRANT SELECT ON api.%I TO tenant_a,tenant_b',n);
 END LOOP;
 FOREACH n IN ARRAY ARRAY['task_execution_output','task_execution_output_entity','material_movement','material_posting','observation','assessment','material','location'] LOOP
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON api.%I FOR EACH ROW EXECUTE FUNCTION api.immutable()',n);
 END LOOP;
END $$;
GRANT USAGE ON SCHEMA api TO tenant_a,tenant_b;
GRANT EXECUTE ON FUNCTION api.tenant() TO tenant_a,tenant_b;
COMMIT;
