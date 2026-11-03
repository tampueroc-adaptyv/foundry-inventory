\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
SELECT pg_advisory_xact_lock(741903);

ALTER TABLE api.task ADD COLUMN initiation_issuer text,
 ADD COLUMN initiation_namespace text, ADD COLUMN initiation_key text,
 ADD COLUMN initiation_request jsonb, ADD COLUMN initiation_provenance jsonb,
 ADD COLUMN canonicalizer text NOT NULL DEFAULT 'exact-json@1',
 ADD COLUMN owner_task uuid,
 ADD FOREIGN KEY(tenant_id,owner_task) REFERENCES api.task(tenant_id,id) DEFERRABLE INITIALLY DEFERRED;
-- Explicitly unknown historical actor, not an assertion about an old issuer.
UPDATE api.task SET initiation_issuer='legacy-unattributed',initiation_namespace='legacy',initiation_key=request_key,
 initiation_request=jsonb_build_object('spec',spec_id,'intent',intent),initiation_provenance='{"source":"legacy-unattributed"}';
ALTER TABLE api.task ALTER initiation_issuer SET NOT NULL, ALTER initiation_namespace SET NOT NULL,
 ALTER initiation_key SET NOT NULL, ALTER initiation_request SET NOT NULL, ALTER initiation_provenance SET NOT NULL,
 ADD UNIQUE(tenant_id,initiation_issuer,initiation_namespace,initiation_key),
 ADD CHECK(owner_task IS DISTINCT FROM id);
ALTER TABLE api.task_execution ADD COLUMN start_issuer text, ADD COLUMN start_namespace text,
 ADD COLUMN start_key text, ADD COLUMN start_request jsonb, ADD COLUMN invocation jsonb,
 ADD COLUMN canonicalizer text NOT NULL DEFAULT 'exact-json@1';
UPDATE api.task_execution SET start_issuer='legacy-unattributed',start_namespace='unkeyed',start_key=id::text,
 start_request=jsonb_build_object('task',task_id,'workcell',workcell);
ALTER TABLE api.task_execution ALTER start_issuer SET NOT NULL, ALTER start_namespace SET NOT NULL,
 ALTER start_key SET NOT NULL, ALTER start_request SET NOT NULL,
 ADD UNIQUE(tenant_id,start_issuer,start_namespace,start_key);

CREATE FUNCTION api.initiation_defaults() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
BEGIN
 IF TG_TABLE_NAME='task' THEN
  NEW.initiation_issuer:=coalesce(NEW.initiation_issuer,'legacy-unattributed');
  NEW.initiation_namespace:=coalesce(NEW.initiation_namespace,'legacy');
  NEW.initiation_key:=coalesce(NEW.initiation_key,NEW.request_key);
  NEW.initiation_request:=coalesce(NEW.initiation_request,jsonb_build_object('spec',NEW.spec_id,'intent',NEW.intent));
  NEW.initiation_provenance:=coalesce(NEW.initiation_provenance,'{"source":"legacy-unattributed"}');
 ELSE
  NEW.start_issuer:=coalesce(NEW.start_issuer,'legacy-unattributed');
  NEW.start_namespace:=coalesce(NEW.start_namespace,'unkeyed');
  NEW.start_key:=coalesce(NEW.start_key,NEW.id::text);
  NEW.start_request:=coalesce(NEW.start_request,jsonb_build_object('task',NEW.task_id,'workcell',NEW.workcell));
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER initiation_defaults BEFORE INSERT ON api.task FOR EACH ROW EXECUTE FUNCTION api.initiation_defaults();
CREATE TRIGGER initiation_defaults BEFORE INSERT ON api.task_execution FOR EACH ROW EXECUTE FUNCTION api.initiation_defaults();
CREATE FUNCTION api.frozen_work() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'planned work is immutable'; END IF;
 IF TG_TABLE_NAME='task' THEN
  IF (to_jsonb(NEW)-ARRAY['state','seq','last_output']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['state','seq','last_output']) THEN RAISE EXCEPTION 'frozen Task identity/bindings'; END IF;
 ELSE
  IF (to_jsonb(NEW)-ARRAY['state','terminal_output']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['state','terminal_output']) THEN RAISE EXCEPTION 'frozen invocation'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER frozen_work BEFORE UPDATE OR DELETE ON api.task FOR EACH ROW EXECUTE FUNCTION api.frozen_work();
CREATE TRIGGER frozen_work BEFORE UPDATE OR DELETE ON api.task_execution FOR EACH ROW EXECUTE FUNCTION api.frozen_work();

-- Issuer is taken only from authenticated role/signed claims, never RPC input.
-- The demo trusts these assertions; no additional IAM system is introduced.
CREATE FUNCTION api.initiator() RETURNS text LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_array(current_setting('role'),
 coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'iss','role'),
 coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub','role'))::text
$$;

INSERT INTO api.task_spec_catalog(tenant_id,id,version,handler,definition)
 SELECT t,'assay@1',1,'v1','{"kind":"correction","ports":["checkpoint","terminal"],"required_ports":["checkpoint"],"repeatable":true}'::jsonb FROM unnest(ARRAY['a','b']) t;
INSERT INTO api.task_spec_catalog(tenant_id,id,version,handler,definition)
 SELECT t,'bounded-workflow@1',1,'v1',
 '{"kind":"composite","workflow_handler":"bounded@1","ports":["membership","coordination","terminal"],"required_ports":["coordination"],"roles":[{"role":"first","min":1,"max":2},{"role":"second","min":1,"max":2}],"completion":"all-selected","task_completion":"explicit","child_specs":["assay@1","transfer@1","scoped-transfer-task@1","scoped-transfer-workflow@1","scoped-transfer-site@1","scoped-transfer-site@2","scoped-transfer-tenant@1"]}'::jsonb FROM unnest(ARRAY['a','b']) t;

-- New admission deliberately does not inspect balances, pending commands,
-- occupancy, closure, placement predecessor or execution workcell readiness.
CREATE FUNCTION api.validate_admission(t text,spec text,i jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE h api.container_content; c api.container; x jsonb; keys text[]:='{}'; work jsonb; d text;
BEGIN
 PERFORM api.require_fields(i);
 IF i ?| ARRAY['owner_task','replacement','predecessor','members'] THEN RAISE EXCEPTION 'ownership/replanning is not an ordinary Task input'; END IF;
 IF NOT EXISTS(SELECT 1 FROM api.task_spec_catalog WHERE tenant_id=t AND id=spec) THEN RAISE EXCEPTION 'unknown specification'; END IF;
 IF spec IN ('assay@1','correction@1') THEN
  IF i-ARRAY['dependencies','parameters']<>'{}'::jsonb THEN RAISE EXCEPTION 'unsupported assay inputs'; END IF;
  RETURN i;
 ELSIF spec='receipt@1' THEN
  PERFORM api.require_fields(i,ARRAY['supplier','delivery','line','lot','holding','unit'],ARRAY['quantity']);
  SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(i->>'holding')::uuid;
  PERFORM api.physical_quantity((i->>'quantity')::numeric,i->>'unit',h.dimension);
  RETURN i;
 ELSIF spec='transfer@1' OR spec LIKE 'scoped-transfer-%' THEN
  IF i-ARRAY['items','semantic','dependencies']<>'{}'::jsonb OR (spec='transfer@1' AND i ? 'semantic') THEN RAISE EXCEPTION 'unsupported or undeclared transfer inputs'; END IF;
  IF (jsonb_array_length(i->'items') BETWEEN 1 AND 384) IS NOT TRUE THEN RAISE EXCEPTION 'work items required'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(i->'items') LOOP
   PERFORM api.require_fields(x,ARRAY['key','source','destination','unit'],ARRAY['quantity']);
   IF x->>'key'=ANY(keys) THEN RAISE EXCEPTION 'duplicate work key'; END IF; keys:=keys||(x->>'key');
   SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(x->>'source')::uuid;
   IF NOT EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=t AND id=(x->>'destination')::uuid AND material_id=h.material_id AND dimension=h.dimension AND id<>h.id) THEN RAISE EXCEPTION 'incompatible destination'; END IF;
   PERFORM api.physical_quantity((x->>'quantity')::numeric,x->>'unit',h.dimension);
  END LOOP;
  RETURN i;
 END IF;
 IF spec NOT IN ('inventory-register@1','reconstitute@1','consume@1','dispose@1','relocate@1') THEN RAISE EXCEPTION 'unsupported keyed admission contract'; END IF;
 IF i - (CASE spec WHEN 'inventory-register@1' THEN ARRAY['operation','spec','barcode','parent','location','position','container','material','material_spec','label','supplier_identity','dependencies'] WHEN 'relocate@1' THEN ARRAY['container','parent','location','position','expected_seq','dependencies'] WHEN 'reconstitute@1' THEN ARRAY['source','destination','quantity','unit','output_quantity','output_unit','method','reason','label','dependencies'] ELSE ARRAY['source','quantity','unit','reason','dependencies'] END) <> '{}'::jsonb THEN RAISE EXCEPTION 'unsupported governed inventory input'; END IF;
 IF i ? 'items' THEN RAISE EXCEPTION 'work keys are server-owned'; END IF;
 IF spec='inventory-register@1' THEN
  PERFORM api.require_fields(i,ARRAY['operation']); work:='[]';
  IF i->>'operation'='container' THEN
   PERFORM api.require_fields(i,ARRAY['spec','barcode','position']);
   IF i->>'spec' NOT IN ('tube@1','plate384@1','rack@1') OR num_nonnulls(i->>'parent',i->>'location')<>1 THEN RAISE EXCEPTION 'invalid planned container'; END IF;
   IF i->>'parent' IS NOT NULL THEN SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'parent')::uuid;
   ELSE PERFORM 1 FROM api.location WHERE tenant_id=t AND id=(i->>'location')::uuid; IF NOT FOUND THEN RAISE EXCEPTION 'invalid location'; END IF; END IF;
  ELSIF i->>'operation' IN ('stock','holding') THEN
   SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'container')::uuid;
   IF c.spec_id NOT IN ('tube@1','well@1') THEN RAISE EXCEPTION 'incompatible direct container'; END IF;
   IF i->>'operation'='stock' THEN
    PERFORM api.require_fields(i,ARRAY['label','material_spec']); PERFORM api.require_fields(i->'supplier_identity',ARRAY['supplier','lot']);
    IF i->>'material_spec'<>'purchased-powder@1' THEN RAISE EXCEPTION 'unsupported material'; END IF;
   ELSE PERFORM 1 FROM api.material WHERE tenant_id=t AND id=(i->>'material')::uuid; IF NOT FOUND THEN RAISE EXCEPTION 'invalid material'; END IF; END IF;
  ELSE RAISE EXCEPTION 'unsupported registration'; END IF;
 ELSIF spec='relocate@1' THEN
  PERFORM api.require_fields(i,ARRAY['container','position'],ARRAY['expected_seq']);
  SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'container')::uuid;
  IF c.fixed OR num_nonnulls(i->>'parent',i->>'location')<>1 THEN RAISE EXCEPTION 'invalid planned relocation'; END IF;
  IF i->>'parent' IS NOT NULL THEN PERFORM 1 FROM api.container WHERE tenant_id=t AND id=(i->>'parent')::uuid;
  ELSE PERFORM 1 FROM api.location WHERE tenant_id=t AND id=(i->>'location')::uuid; END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'invalid destination'; END IF; work:='[{"key":"move"}]';
 ELSE
  PERFORM api.require_fields(i,ARRAY['source','unit','reason'],ARRAY['quantity']);
  SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(i->>'source')::uuid;
  PERFORM api.physical_quantity((i->>'quantity')::numeric,i->>'unit',h.dimension);
  IF spec='reconstitute@1' THEN
   PERFORM api.require_fields(i,ARRAY['destination','method','output_unit'],ARRAY['output_quantity']);
   IF i->>'method'<>'reconstitute@1' THEN RAISE EXCEPTION 'unsupported method'; END IF;
   SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'destination')::uuid;
   PERFORM api.physical_quantity((i->>'output_quantity')::numeric,i->>'output_unit','volume'); work:='[{"key":"input"},{"key":"output"}]';
  ELSE work:='[{"key":"use"}]'; END IF;
 END IF;
 RETURN i||jsonb_build_object('items',work);
END $$;

CREATE FUNCTION api.admit_task(spec text,namespace text,request_key text,intent jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); who text:=api.initiator(); r jsonb:=jsonb_build_object('spec',spec,'intent',intent); v api.task; frozen jsonb;
BEGIN
 PERFORM api.require_fields(jsonb_build_object('namespace',namespace,'key',request_key),ARRAY['namespace','key']);
 SELECT * INTO v FROM api.task WHERE tenant_id=t AND initiation_issuer=who AND initiation_namespace=namespace AND initiation_key=request_key;
 IF FOUND THEN IF v.initiation_request IS DISTINCT FROM r THEN RAISE EXCEPTION 'conflicting initiation retry'; END IF; RETURN v.id; END IF;
 frozen:=api.validate_admission(t,spec,intent);
 INSERT INTO api.task(tenant_id,spec_id,request_key,intent,initiation_issuer,initiation_namespace,initiation_key,initiation_request,initiation_provenance,supplier,delivery,source_line)
 VALUES(t,spec,'keyed/'||pg_catalog.uuidv7(),frozen,who,namespace,request_key,r,jsonb_build_object('authenticated',who,'namespace',namespace),CASE WHEN spec='receipt@1' THEN intent->>'supplier' END,CASE WHEN spec='receipt@1' THEN intent->>'delivery' END,CASE WHEN spec='receipt@1' THEN intent->>'line' END) RETURNING id INTO v.id;
 RETURN v.id;
END $$;

-- All selection consumers share this exact qualifier. Target Task identity is
-- distinct from the actual producer of an authorized cross-Task transition.
CREATE FUNCTION api.select_dependency(t text,d jsonb,s jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE o api.task_execution_output; e api.task_execution; target api.task; a api.assessment; obs api.observation;
BEGIN
 PERFORM api.require_fields(d,ARRAY['role','task','spec','port','mode']);
 PERFORM api.require_fields(s,ARRAY['execution','output']);
 SELECT * INTO STRICT target FROM api.task WHERE tenant_id=t AND id=(d->>'task')::uuid AND spec_id=d->>'spec';
 SELECT * INTO STRICT o FROM api.task_execution_output WHERE tenant_id=t AND id=(s->>'output')::uuid AND execution_id=(s->>'execution')::uuid AND port=d->>'port';
 SELECT * INTO STRICT e FROM api.task_execution WHERE tenant_id=t AND id=o.execution_id AND spec_id=o.spec_id;
 IF o.port='transition' THEN
  SELECT * INTO STRICT a FROM api.assessment WHERE tenant_id=t AND id=(o.payload->>'assessment')::uuid AND subject_type='task' AND subject_id=target.id;
  IF a.result->>'outcome' IS DISTINCT FROM 'pass' OR a.spec_id IS DISTINCT FROM (SELECT definition->>'completion_assessment' FROM api.task_spec_catalog WHERE tenant_id=t AND id=target.spec_id) THEN RAISE EXCEPTION 'invalid completion authority'; END IF;
  IF o.payload->>'target' IS DISTINCT FROM target.id::text OR NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=t AND output_id=o.id AND role='target-task' AND target_type='task' AND target_id=target.id) THEN RAISE EXCEPTION 'wrong transition target'; END IF;
 ELSE
  IF e.task_id<>target.id OR o.spec_id<>target.spec_id THEN RAISE EXCEPTION 'wrong result producer'; END IF;
 END IF;
 IF o.port='terminal' AND o.payload->>'state' IS DISTINCT FROM 'Completed' THEN RAISE EXCEPTION 'unsuccessful prerequisite'; END IF;
 IF d->>'mode' NOT IN ('historical','live') THEN RAISE EXCEPTION 'invalid dependency mode'; END IF;
 IF d ? 'output' AND d->>'output' IS DISTINCT FROM s->>'output' THEN RAISE EXCEPTION 'frozen result changed'; END IF;
 IF d ? 'execution' AND d->>'execution' IS DISTINCT FROM s->>'execution' THEN RAISE EXCEPTION 'frozen attempt changed'; END IF;
 IF d ? 'member' AND d->>'member' IS DISTINCT FROM s->>'member' THEN RAISE EXCEPTION 'frozen member changed'; END IF;
 IF d->>'mode'='live' THEN
  IF o.port<>'transition' THEN SELECT * INTO STRICT a FROM api.assessment WHERE tenant_id=t AND output_id=o.id AND member=s->>'member'; END IF;
  IF NOT api.valid_assessment(t,a.id) OR (a.result->>'outcome' IN ('pass','binding')) IS NOT TRUE THEN RAISE EXCEPTION 'stale prerequisite approval'; END IF;
 ELSIF coalesce(s->>'member','')<>'' THEN
  IF NOT EXISTS(SELECT 1 FROM api.assessment WHERE tenant_id=t AND output_id=o.id AND member=s->>'member') AND NOT EXISTS(SELECT 1 FROM api.observation ob, jsonb_array_elements(ob.mapping) m WHERE ob.tenant_id=t AND ob.output_id=o.id AND m->>'member'=s->>'member') THEN RAISE EXCEPTION 'unknown scientific member'; END IF;
 END IF;
 RETURN d||jsonb_build_object('execution',e.id,'output',o.id,'member',coalesce(s->>'member',''),'producer_task',e.task_id,'output_spec',o.spec_id,'assessment',a.id,'assessment_spec',a.spec_id);
END $$;
CREATE OR REPLACE FUNCTION api.prerequisites(t text,intent jsonb) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE d jsonb; BEGIN
 FOR d IN SELECT * FROM jsonb_array_elements(coalesce(intent->'dependencies','[]')) LOOP
  -- Legacy contracts omitted role. It remains a stable positional-independent target label.
  PERFORM api.select_dependency(t,jsonb_build_object('role',coalesce(d->>'role','legacy'))||d,d);
 END LOOP;
END $$;

CREATE FUNCTION api.start_task(task uuid,namespace text,request_key text,workcell text,selections jsonb DEFAULT '[]') RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); who text:=api.initiator(); r jsonb:=jsonb_build_object('task',task,'workcell',workcell,'selections',selections);
 v api.task; old api.task_execution; eid uuid; deps jsonb:='[]'; d jsonb; s jsonb; contract jsonb; o uuid; m jsonb;
BEGIN
 PERFORM api.require_fields(jsonb_build_object('namespace',namespace,'key',request_key),ARRAY['namespace','key']);
 SELECT * INTO old FROM api.task_execution WHERE tenant_id=t AND start_issuer=who AND start_namespace=namespace AND start_key=request_key;
 IF FOUND THEN IF old.start_request IS DISTINCT FROM r THEN RAISE EXCEPTION 'conflicting start retry'; END IF; RETURN old.id; END IF;
 SELECT * INTO STRICT v FROM api.task WHERE tenant_id=t AND id=task;
 SELECT definition INTO STRICT contract FROM api.task_spec_catalog WHERE tenant_id=t AND id=v.spec_id;
 IF v.state<>'Pending' THEN RAISE EXCEPTION 'task not pending'; END IF;
 IF NOT EXISTS(SELECT 1 FROM api.location WHERE tenant_id=t AND location.workcell=start_task.workcell) THEN RAISE EXCEPTION 'workcell not authorized'; END IF;
 IF jsonb_typeof(selections) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'selection array required'; END IF;
 IF contract->>'kind'<>'composite' THEN
  IF jsonb_array_length(selections) NOT IN (0,jsonb_array_length(coalesce(v.intent->'dependencies','[]'))) THEN RAISE EXCEPTION 'complete selections required'; END IF;
  FOR d IN SELECT * FROM jsonb_array_elements(coalesce(v.intent->'dependencies','[]')) LOOP
   IF jsonb_array_length(selections)=0 THEN s:=d;
   ELSE SELECT x INTO STRICT s FROM jsonb_array_elements(selections) x WHERE x->>'role'=d->>'role';
    IF s-ARRAY['role','execution','output','member']<>'{}'::jsonb THEN RAISE EXCEPTION 'unsupported invocation override'; END IF;
   END IF;
   deps:=deps||jsonb_build_array(api.select_dependency(t,d,s));
  END LOOP;
 ELSE
  IF selections<>'[]'::jsonb THEN RAISE EXCEPTION 'coordination selections belong to evaluation'; END IF;
 END IF;
 IF v.spec_id IN ('inventory-register@1','reconstitute@1','consume@1','dispose@1','relocate@1') THEN PERFORM api.validate_inventory_intent(t,v.spec_id,v.intent,workcell); END IF;
 INSERT INTO api.task_execution(tenant_id,task_id,spec_id,attempt,workcell,start_issuer,start_namespace,start_key,start_request,invocation)
 SELECT t,task,v.spec_id,coalesce(max(attempt),0)+1,workcell,who,namespace,request_key,r,v.intent||jsonb_build_object('dependencies',deps,'workcell',workcell)
 FROM api.task_execution WHERE tenant_id=t AND task_id=task RETURNING id INTO eid;
 IF contract->>'workflow_handler'='bounded@1' THEN
  INSERT INTO api.task_execution_output(tenant_id,execution_id,spec_id,request_key,port,request,payload,actor)
  VALUES(t,eid,v.spec_id,'membership','membership','{}',jsonb_build_object('members',v.intent->'members'),who) RETURNING id INTO o;
  FOR m IN SELECT * FROM jsonb_array_elements(v.intent->'members') LOOP PERFORM api.edge(t,o,m->>'name','owned-child','task',(m->>'task')::uuid,m->>'role'); END LOOP;
 END IF;
 RETURN eid;
END $$;
-- Command readiness uses the resolved immutable invocation, not unresolved intent.
DO $$ DECLARE b text; BEGIN
 b:=pg_get_functiondef('api.accept(uuid,text,text,jsonb)'::regprocedure);
 b:=replace(b,'api.prerequisites(t,taskrow.intent)','api.prerequisites(t,coalesce(e.invocation,taskrow.intent))'); EXECUTE b;
 b:=pg_get_functiondef('api.validate_inventory_intent(text,text,jsonb,text)'::regprocedure);
 b:=replace(b,'allowed||ARRAY[''items'']','allowed||ARRAY[''items'',''dependencies'']'); EXECUTE b;
END $$;

CREATE FUNCTION api.create_workflow(namespace text,request_key text,children jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); who text:=api.initiator(); r jsonb:=jsonb_build_object('spec','bounded-workflow@1','children',children);
 v api.task; parent uuid:=pg_catalog.uuidv7(); child jsonb; plan jsonb:='[]'; deps jsonb; d jsonb; x jsonb; frozen jsonb; n text; names text[]:='{}'; role_name text; cnt integer;
BEGIN
 PERFORM api.require_fields(jsonb_build_object('namespace',namespace,'key',request_key),ARRAY['namespace','key']);
 SELECT * INTO v FROM api.task WHERE tenant_id=t AND initiation_issuer=who AND initiation_namespace=namespace AND initiation_key=request_key;
 IF FOUND THEN IF v.initiation_request IS DISTINCT FROM r THEN RAISE EXCEPTION 'conflicting workflow retry'; END IF; RETURN v.id; END IF;
 IF jsonb_typeof(children) IS DISTINCT FROM 'array' OR jsonb_array_length(children) NOT BETWEEN 2 AND 4 THEN RAISE EXCEPTION 'complete child set required'; END IF;
 FOR child IN SELECT * FROM jsonb_array_elements(children) LOOP
  PERFORM api.require_fields(child,ARRAY['name','role','spec']); n:=child->>'name';
  IF child-ARRAY['name','role','spec','intent','after']<>'{}'::jsonb OR n=ANY(names) OR n !~ '^[a-z][a-z0-9_-]{0,31}$' THEN RAISE EXCEPTION 'invalid/duplicate child or unsupported ownership/replanning'; END IF;
  names:=names||n;
  IF child->>'role' NOT IN ('first','second') OR NOT EXISTS(SELECT 1 FROM api.task_spec_catalog WHERE tenant_id=t AND id='bounded-workflow@1' AND definition->'child_specs' ? (child->>'spec')) THEN RAISE EXCEPTION 'invalid child specification; nested ownership unsupported'; END IF;
  IF child->'intent' ? 'dependencies' THEN RAISE EXCEPTION 'use explicit after bindings'; END IF;
  plan:=plan||jsonb_build_array(child||jsonb_build_object('task',pg_catalog.uuidv7()));
 END LOOP;
 FOREACH role_name IN ARRAY ARRAY['first','second'] LOOP
  SELECT count(*) INTO cnt FROM jsonb_array_elements(plan) role_member WHERE role_member->>'role'=role_name;
  IF cnt NOT BETWEEN 1 AND 2 THEN RAISE EXCEPTION 'role cardinality'; END IF;
 END LOOP;
 -- after entries are typed selectors: {child,port,mode,member?}. Edges
 -- may point forwards because IDs were preallocated; recursive cycle check below.
 FOR child IN SELECT * FROM jsonb_array_elements(plan) LOOP
  deps:='[]';
  FOR d IN SELECT * FROM jsonb_array_elements(coalesce(child->'after','[]')) LOOP
   PERFORM api.require_fields(d,ARRAY['child','port','mode']);
   SELECT p INTO STRICT x FROM jsonb_array_elements(plan) p WHERE p->>'name'=d->>'child';
   IF d->>'port' NOT IN ('terminal','transition','settlement','checkpoint') OR d->>'mode' NOT IN ('historical','live') THEN RAISE EXCEPTION 'unsupported dependency type'; END IF;
   deps:=deps||jsonb_build_array((d-'child')||jsonb_build_object('role',d->>'child','task',x->>'task','spec',x->>'spec'));
  END LOOP;
  IF (SELECT count(DISTINCT z->>'role') FROM jsonb_array_elements(deps) z)<>jsonb_array_length(deps) THEN RAISE EXCEPTION 'duplicate dependency'; END IF;
  frozen:=api.validate_admission(t,child->>'spec',coalesce(child->'intent','{}')||jsonb_build_object('dependencies',deps));
  INSERT INTO api.task(tenant_id,id,spec_id,request_key,intent,owner_task,initiation_issuer,initiation_namespace,initiation_key,initiation_request,initiation_provenance)
  VALUES(t,(child->>'task')::uuid,child->>'spec','child/'||(child->>'task'),frozen,parent,who,'workflow-child',child->>'task',child-'task',jsonb_build_object('workflow',parent));
 END LOOP;
 IF EXISTS(WITH RECURSIVE edges AS (SELECT c->>'name' src,d->>'child' dst FROM jsonb_array_elements(plan) c CROSS JOIN LATERAL jsonb_array_elements(coalesce(c->'after','[]')) d), walk(src,dst,path,cycle) AS (SELECT src,dst,ARRAY[src,dst],src=dst FROM edges UNION ALL SELECT w.src,e.dst,w.path||e.dst,e.dst=ANY(w.path) FROM walk w JOIN edges e ON w.dst=e.src WHERE NOT w.cycle) SELECT 1 FROM walk WHERE cycle) THEN RAISE EXCEPTION 'dependency cycle'; END IF;
 INSERT INTO api.task(tenant_id,id,spec_id,request_key,intent,initiation_issuer,initiation_namespace,initiation_key,initiation_request,initiation_provenance)
 VALUES(t,parent,'bounded-workflow@1','workflow/'||parent,jsonb_build_object('members',plan),who,namespace,request_key,r,jsonb_build_object('authenticated',who,'namespace',namespace));
 RETURN parent;
END $$;

CREATE FUNCTION api.workflow_membership_integrity() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE p api.task; m jsonb; n integer;
BEGIN
 IF NEW.owner_task IS NOT NULL THEN
  SELECT * INTO STRICT p FROM api.task WHERE tenant_id=NEW.tenant_id AND id=NEW.owner_task AND spec_id='bounded-workflow@1' AND owner_task IS NULL;
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p.intent->'members') x WHERE x->>'task'=NEW.id::text AND x->>'spec'=NEW.spec_id) THEN RAISE EXCEPTION 'reciprocal ownership mismatch'; END IF;
 END IF;
 IF NEW.spec_id='bounded-workflow@1' THEN
  IF NEW.owner_task IS NOT NULL OR jsonb_typeof(NEW.intent->'members') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'invalid composite/nesting'; END IF;
  SELECT count(*) INTO n FROM api.task WHERE tenant_id=NEW.tenant_id AND owner_task=NEW.id;
  IF n<>jsonb_array_length(NEW.intent->'members') OR n NOT BETWEEN 2 AND 4 THEN RAISE EXCEPTION 'incomplete owned membership'; END IF;
  FOR m IN SELECT * FROM jsonb_array_elements(NEW.intent->'members') LOOP
   IF NOT EXISTS(SELECT 1 FROM api.task WHERE tenant_id=NEW.tenant_id AND id=(m->>'task')::uuid AND owner_task=NEW.id AND spec_id=m->>'spec') THEN RAISE EXCEPTION 'invalid owned member'; END IF;
  END LOOP;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER workflow_membership AFTER INSERT ON api.task DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.workflow_membership_integrity();

CREATE FUNCTION api.planned_dependencies_integrity() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE d jsonb; target api.task; contract jsonb;
BEGIN
 FOR d IN SELECT * FROM jsonb_array_elements(coalesce(NEW.intent->'dependencies','[]')) LOOP
  PERFORM api.require_fields(d,ARRAY['task','spec','port','mode']);
  SELECT * INTO STRICT target FROM api.task WHERE tenant_id=NEW.tenant_id AND id=(d->>'task')::uuid AND spec_id=d->>'spec';
  SELECT definition INTO STRICT contract FROM api.task_spec_catalog WHERE tenant_id=NEW.tenant_id AND id=target.spec_id;
  IF ((contract->'ports' ? (d->>'port')) OR (d->>'port'='transition' AND contract ? 'completion_assessment')) IS NOT TRUE OR (d->>'mode' IN ('historical','live')) IS NOT TRUE THEN RAISE EXCEPTION 'invalid planned dependency contract'; END IF;
 END LOOP;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER planned_dependencies AFTER INSERT ON api.task DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.planned_dependencies_integrity();

CREATE VIEW api.workflow_specification WITH (security_invoker=true) AS SELECT id,version,definition,to_jsonb(published_at) AS publication FROM api.task_spec_catalog WHERE definition->>'workflow_handler'='bounded@1';
CREATE VIEW api.workflow WITH (security_invoker=true) AS SELECT id,spec_id,state,seq,last_output,initiation_provenance,intent->'members' AS children FROM api.task WHERE spec_id='bounded-workflow@1';
GRANT SELECT ON api.workflow_specification,api.workflow TO tenant_a,tenant_b;
GRANT EXECUTE ON FUNCTION api.admit_task(text,text,text,jsonb),api.start_task(uuid,text,text,text,jsonb),api.create_workflow(text,text,jsonb) TO tenant_a,tenant_b;

CREATE FUNCTION api.workflow_selection(t text,w uuid,selections jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE v api.task; m jsonb; s jsonb; d jsonb; result jsonb:='[]';
BEGIN
 SELECT * INTO STRICT v FROM api.task WHERE tenant_id=t AND id=w AND spec_id='bounded-workflow@1';
 IF jsonb_typeof(selections) IS DISTINCT FROM 'array' OR jsonb_array_length(selections)<>jsonb_array_length(v.intent->'members') THEN RAISE EXCEPTION 'complete workflow selections required'; END IF;
 FOR m IN SELECT * FROM jsonb_array_elements(v.intent->'members') LOOP
  SELECT x INTO STRICT s FROM jsonb_array_elements(selections) x WHERE x->>'role'=m->>'name';
  IF (s->>'port' IN ('terminal','transition')) IS NOT TRUE THEN RAISE EXCEPTION 'completion evidence required'; END IF;
  d:=jsonb_build_object('role',m->>'name','task',m->>'task','spec',m->>'spec','port',s->>'port','mode',CASE WHEN s->>'port'='transition' THEN 'live' ELSE 'historical' END);
  result:=result||jsonb_build_array(api.select_dependency(t,d,s));
 END LOOP;
 RETURN result;
END $$;
CREATE FUNCTION api.evaluate_workflow(execution uuid,request_key text,selections jsonb,complete_task boolean DEFAULT false,expected_seq bigint DEFAULT 0) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); e api.task_execution; v api.task; old api.task_execution_output; o uuid; facts jsonb; f jsonb; p jsonb;
 r jsonb:=jsonb_build_object('selections',selections,'complete_task',complete_task,'expected_seq',expected_seq);
BEGIN
 SELECT * INTO STRICT e FROM api.task_execution WHERE tenant_id=t AND id=execution AND spec_id='bounded-workflow@1';
 SELECT * INTO old FROM api.task_execution_output WHERE tenant_id=t AND execution_id=execution AND task_execution_output.request_key=evaluate_workflow.request_key;
 IF FOUND THEN IF old.request IS DISTINCT FROM r THEN RAISE EXCEPTION 'conflicting evaluation retry'; END IF; RETURN old.id; END IF;
 SELECT * INTO STRICT v FROM api.task WHERE tenant_id=t AND id=e.task_id;
 IF e.state<>'Running' OR complete_task IS NULL THEN RAISE EXCEPTION 'evaluation not permitted'; END IF;
 facts:=api.workflow_selection(t,v.id,selections);
 p:=jsonb_build_object('selections',facts,'workflow',v.id,'complete_task',complete_task);
 IF complete_task THEN
  IF v.state<>'Pending' OR v.seq IS DISTINCT FROM expected_seq THEN RAISE EXCEPTION 'workflow predecessor conflict'; END IF;
  p:=p||jsonb_build_object('before','Pending','after','Completed','expected_seq',v.seq,'resulting_seq',v.seq+1,'predecessor',v.last_output);
 END IF;
 INSERT INTO api.task_execution_output(tenant_id,execution_id,spec_id,request_key,port,request,payload,actor)
 VALUES(t,e.id,e.spec_id,request_key,'coordination',r,p,api.initiator()) RETURNING id INTO o;
 FOR f IN SELECT * FROM jsonb_array_elements(facts) LOOP
  PERFORM api.edge(t,o,f->>'role','child-task','task',(f->>'task')::uuid);
  PERFORM api.edge(t,o,f->>'role','selected-execution','execution',(f->>'execution')::uuid);
  PERFORM api.edge(t,o,f->>'role','selected-output','output',(f->>'output')::uuid,f->>'member');
 END LOOP;
 IF complete_task THEN UPDATE api.task SET state='Completed',seq=seq+1,last_output=o WHERE tenant_id=t AND id=v.id; END IF;
 RETURN o;
END $$;
CREATE FUNCTION api.workflow_output_integrity() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE w uuid; facts jsonb; f jsonb; n integer;
BEGIN
 IF NEW.spec_id<>'bounded-workflow@1' THEN RETURN NULL; END IF;
 SELECT task_id INTO STRICT w FROM api.task_execution WHERE tenant_id=NEW.tenant_id AND id=NEW.execution_id;
 IF NEW.port='coordination' THEN
  facts:=api.workflow_selection(NEW.tenant_id,w,NEW.payload->'selections');
  IF facts IS DISTINCT FROM NEW.payload->'selections' OR NEW.payload->>'workflow' IS DISTINCT FROM w::text THEN RAISE EXCEPTION 'invalid workflow selection projection'; END IF;
  SELECT count(*) INTO n FROM api.task_execution_output_entity WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id;
  IF n<>3*jsonb_array_length(facts) THEN RAISE EXCEPTION 'incomplete workflow provenance'; END IF;
  FOR f IN SELECT * FROM jsonb_array_elements(facts) LOOP
   IF NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id AND member=f->>'role' AND role='selected-output' AND target_type='output' AND target_id=(f->>'output')::uuid AND selector=f->>'member') OR
    NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id AND member=f->>'role' AND role='selected-execution' AND target_type='execution' AND target_id=(f->>'execution')::uuid) OR
    NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id AND member=f->>'role' AND role='child-task' AND target_type='task' AND target_id=(f->>'task')::uuid) THEN RAISE EXCEPTION 'wrong workflow provenance'; END IF;
  END LOOP;
  IF NEW.payload->>'complete_task'='true' AND NOT EXISTS(SELECT 1 FROM api.task WHERE tenant_id=NEW.tenant_id AND id=w AND state='Completed' AND last_output=NEW.id AND seq=(NEW.payload->>'resulting_seq')::bigint) THEN RAISE EXCEPTION 'workflow transition mismatch'; END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER workflow_output_integrity AFTER INSERT ON api.task_execution_output DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.workflow_output_integrity();
CREATE FUNCTION api.workflow_progress(workflow uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); v api.task; o api.task_execution_output; valid boolean:=false;
BEGIN
 SELECT * INTO STRICT v FROM api.task WHERE tenant_id=t AND id=workflow AND spec_id='bounded-workflow@1';
 SELECT z.* INTO o FROM api.task_execution_output z JOIN api.task_execution e ON (e.tenant_id,e.id)=(z.tenant_id,z.execution_id) WHERE z.tenant_id=t AND e.task_id=v.id AND z.port='coordination' ORDER BY z.accepted_order DESC LIMIT 1;
 IF o.id IS NOT NULL THEN
  BEGIN PERFORM api.workflow_selection(t,v.id,o.payload->'selections'); valid:=true;
  EXCEPTION WHEN raise_exception OR no_data_found OR too_many_rows THEN valid:=false; END;
 END IF;
 RETURN jsonb_build_object('id',v.id,'historical_state',v.state,'children',v.intent->'members','evaluation',o.id,'selections',o.payload->'selections','current_basis_valid',valid,'current_complete',valid AND v.state='Completed');
END $$;
GRANT EXECUTE ON FUNCTION api.evaluate_workflow(uuid,text,jsonb,boolean,bigint),api.workflow_progress(uuid) TO tenant_a,tenant_b;
NOTIFY pgrst,'reload schema';
COMMIT;
