\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
SELECT pg_advisory_xact_lock(741903);

-- Stable site identities with explicit specification meaning. Existing site
-- labels are only the trusted enrollment mapping to these immutable anchors.
INSERT INTO api.location_spec_catalog(tenant_id,id,version,handler,definition)
 SELECT t,'semantic-site@1',1,'v1','{"identity_role":"site-authority","physical":false}'::jsonb FROM unnest(ARRAY['a','b']) t;
INSERT INTO api.location(tenant_id,spec_id,name,site)
 SELECT t,'semantic-site@1','semantic authority/'||s,s FROM unnest(ARRAY['a','b']) t CROSS JOIN unnest(ARRAY['site1','site2']) s;
CREATE UNIQUE INDEX semantic_site_anchor ON api.location(tenant_id,site) WHERE spec_id='semantic-site@1';

-- A small fixed vocabulary, not a user expression language. Compatible v2 uses
-- the exact same family, scope and canonicalizer. Workcell policy is disabled.
INSERT INTO api.task_spec_catalog(tenant_id,id,version,handler,definition)
 SELECT t,'scoped-transfer-'||s||'@'||v,v,'v1',jsonb_build_object('kind','transfer','ports',jsonb_build_array('command','settlement','terminal','checkpoint'),'required_ports',jsonb_build_array('command','checkpoint'),'recovery','settlement',
 'semantic',jsonb_build_object('family','transfer-once/'||s,'scope',s,'policy','finite-transfer@1','canonicalizer','source-occurrence@1'))
 FROM unnest(ARRAY['a','b']) t CROSS JOIN (VALUES('task',1),('workflow',1),('site',1),('site',2),('tenant',1)) q(s,v);
CREATE FUNCTION api.finite_policy_publication() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE scope text; expected jsonb;
BEGIN
 IF NEW.id LIKE 'scoped-transfer-%' OR NEW.definition ? 'semantic' THEN
  scope:=substring(NEW.id FROM '^scoped-transfer-(task|workflow|site|tenant)@[12]$');
  expected:=jsonb_build_object('family','transfer-once/'||scope,'scope',scope,'policy','finite-transfer@1','canonicalizer','source-occurrence@1');
  IF scope IS NULL OR NEW.definition->'semantic' IS DISTINCT FROM expected OR NEW.definition->>'kind' IS DISTINCT FROM 'transfer' OR NEW.handler<>'v1' THEN RAISE EXCEPTION 'unsupported semantic policy or incompatible upgrade'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER finite_policy_publication BEFORE INSERT ON api.task_spec_catalog FOR EACH ROW EXECUTE FUNCTION api.finite_policy_publication();
ALTER TABLE api.task ADD COLUMN semantic_policy jsonb;
CREATE FUNCTION api.pin_semantic_scope() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE policy jsonb; x jsonb; h api.container_content; loc api.location; anchor uuid; scope text; identity text;
BEGIN
 SELECT definition->'semantic' INTO policy FROM api.task_spec_catalog WHERE tenant_id=NEW.tenant_id AND id=NEW.spec_id;
 IF policy IS NULL THEN
  IF NEW.semantic_policy IS NOT NULL OR NEW.intent ? 'semantic' THEN RAISE EXCEPTION 'undeclared semantic policy'; END IF; RETURN NEW;
 END IF;
 IF NEW.semantic_policy IS NOT NULL THEN RAISE EXCEPTION 'scope is server-owned'; END IF;
 IF jsonb_array_length(NEW.intent->'items') IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'finite scoped transfer requires one work item'; END IF;
 PERFORM api.require_fields(NEW.intent->'semantic',ARRAY['namespace','occurrence']);
 IF (NEW.intent->'semantic')-ARRAY['namespace','occurrence']<>'{}'::jsonb OR octet_length((NEW.intent->'semantic')::text)>512 THEN RAISE EXCEPTION 'bounded source occurrence required'; END IF;
 x:=NEW.intent->'items'->0;
 IF EXISTS(SELECT 1 FROM api.task old_task WHERE old_task.tenant_id=NEW.tenant_id AND old_task.semantic_policy IS NULL AND old_task.intent->'semantic'=NEW.intent->'semantic') THEN RAISE EXCEPTION 'legacy consequence identity needs explicit reconciliation'; END IF;
 -- Do not silently activate a new semantic contract on historical physical
 -- scope whose old command has no certifiable consequence identity. An explicit
 -- reconciliation contract is not supplied; such reuse is rejected.
 IF EXISTS(SELECT 1 FROM api.task_execution_output_entity r JOIN api.task_execution_output o ON (o.tenant_id,o.id)=(r.tenant_id,r.output_id) WHERE r.tenant_id=NEW.tenant_id AND r.role='resource' AND r.target_id IN ((x->>'source')::uuid,(x->>'destination')::uuid) AND o.port='command' AND NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity claim WHERE claim.tenant_id=o.tenant_id AND claim.output_id=o.id AND claim.role='semantic-claim' AND claim.claim_phase='ownership')) THEN RAISE EXCEPTION 'legacy physical scope needs explicit semantic reconciliation'; END IF;
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=NEW.tenant_id AND id=(x->>'source')::uuid;
 loc:=api.place(NEW.tenant_id,h.container_id);
 scope:=policy->>'scope';
 CASE scope
 WHEN 'task' THEN identity:=NEW.id::text;
 WHEN 'workflow' THEN
  IF NEW.owner_task IS NULL THEN RAISE EXCEPTION 'owned workflow membership required'; END IF; identity:=NEW.owner_task::text;
 WHEN 'site' THEN
  SELECT id INTO STRICT anchor FROM api.location WHERE tenant_id=NEW.tenant_id AND spec_id='semantic-site@1' AND site=loc.site;
  identity:=anchor::text;
 WHEN 'tenant' THEN identity:=NEW.tenant_id;
 ELSE RAISE EXCEPTION 'unsupported scope: workcell identity prerequisite not enrolled'; END CASE;
 NEW.semantic_policy:=policy||jsonb_build_object('identity',identity,'key',jsonb_build_array(NEW.intent->'semantic'->>'namespace',NEW.intent->'semantic'->>'occurrence')::text,'admission_site',loc.site);
 RETURN NEW;
END $$;
CREATE TRIGGER pin_semantic_scope BEFORE INSERT ON api.task FOR EACH ROW EXECUTE FUNCTION api.pin_semantic_scope();

-- NULL on historical outputs explicitly means no assertion about their writer
-- transaction. New outputs seal relationship membership at transaction commit.
ALTER TABLE api.task_execution_output ADD COLUMN writer_xid xid8;
ALTER TABLE api.task_execution_output ALTER writer_xid SET DEFAULT pg_current_xact_id();
-- Positional inserts must not inherit new column ordering.
DO $$ DECLARE sig text; b text; BEGIN
 FOREACH sig IN ARRAY ARRAY['api.edge(text,uuid,text,text,text,uuid,text)','api.physical_edge(text,uuid,text,text,text,uuid,text)'] LOOP
  b:=pg_get_functiondef(sig::regprocedure);
  b:=replace(b,'INSERT INTO api.task_execution_output_entity VALUES','INSERT INTO api.task_execution_output_entity(tenant_id,output_id,member,role,target_type,target_id,selector) VALUES'); EXECUTE b;
 END LOOP;
END $$;
ALTER TABLE api.task_execution_output_entity
 ADD COLUMN claim_id uuid, ADD COLUMN claim_phase text, ADD COLUMN semantic_family text,
 ADD COLUMN scope_kind text, ADD COLUMN scope_identity text, ADD COLUMN consequence_key text,
 ADD COLUMN policy_pin text, ADD COLUMN ownership_id uuid, ADD COLUMN ownership_phase text,
 ADD CONSTRAINT certified_claim_shape CHECK (
 (role<>'semantic-claim' AND num_nonnulls(claim_id,claim_phase,semantic_family,scope_kind,scope_identity,consequence_key,policy_pin,ownership_id,ownership_phase)=0)
 OR (role='semantic-claim' AND (claim_id IS NOT NULL AND claim_phase IN ('ownership','settlement') AND semantic_family IS NOT NULL
 AND scope_kind IN ('task','workflow','site','tenant') AND scope_identity IS NOT NULL AND consequence_key IS NOT NULL AND policy_pin IS NOT NULL
 AND target_type='task' AND selector=claim_phase
 AND octet_length(semantic_family) BETWEEN 1 AND 64 AND octet_length(scope_identity) BETWEEN 1 AND 256 AND octet_length(consequence_key) BETWEEN 1 AND 512
 AND ((claim_phase='ownership' AND ownership_id IS NULL AND ownership_phase IS NULL)
 OR (claim_phase='settlement' AND ownership_id IS NOT NULL AND ownership_phase='ownership'))) IS TRUE)),
 ADD UNIQUE(tenant_id,claim_id),
 ADD UNIQUE(tenant_id,claim_id,claim_phase,semantic_family,scope_kind,scope_identity,consequence_key),
 ADD CONSTRAINT settlement_ownership FOREIGN KEY(tenant_id,ownership_id,ownership_phase,semantic_family,scope_kind,scope_identity,consequence_key)
 REFERENCES api.task_execution_output_entity(tenant_id,claim_id,claim_phase,semantic_family,scope_kind,scope_identity,consequence_key) DEFERRABLE INITIALLY DEFERRED;
CREATE UNIQUE INDEX semantic_effect_identity ON api.task_execution_output_entity(tenant_id,claim_phase,semantic_family,scope_kind,scope_identity,consequence_key) WHERE role='semantic-claim';

-- Legacy receiving remains protected by its original independent Task source
-- constraint. Activation rejects unresolvable old source identities, rather than
-- fabricating ownership or adding relationships to sealed historical outputs.
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM api.task q JOIN api.task_spec_catalog s ON (s.tenant_id,s.id)=(q.tenant_id,q.spec_id) WHERE s.definition->>'kind'='receipt' AND (
 jsonb_typeof(q.intent->'supplier') IS DISTINCT FROM 'string' OR jsonb_typeof(q.intent->'delivery') IS DISTINCT FROM 'string' OR jsonb_typeof(q.intent->'line') IS DISTINCT FROM 'string' OR
 coalesce(btrim(q.supplier),'')='' OR coalesce(btrim(q.delivery),'')='' OR coalesce(btrim(q.source_line),'')='' OR
 q.supplier IS DISTINCT FROM q.intent->>'supplier' OR q.delivery IS DISTINCT FROM q.intent->>'delivery' OR q.source_line IS DISTINCT FROM q.intent->>'line')) THEN RAISE EXCEPTION 'reconcile ambiguous legacy receiving identities before policy activation'; END IF;
END $$;
CREATE FUNCTION api.claim_manifest(id uuid,phase text,policy jsonb,owner uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('id',id,'phase',phase,'family',policy->>'family','scope',policy->>'scope','identity',policy->>'identity','key',policy->>'key','policy',policy->>'policy','owner',owner)
$$;
CREATE FUNCTION api.certify_effect() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE e api.task_execution; v api.task; p jsonb; claims jsonb:='[]'; own api.task_execution_output_entity; claim_uuid uuid; membership uuid; work text; loc api.location; h api.container_content;
BEGIN
 NEW.payload:=NEW.payload-ARRAY['semantic_claims','semantic_ownership','semantic_work','semantic_scope_basis','invocation'];
 SELECT * INTO STRICT e FROM api.task_execution WHERE tenant_id=NEW.tenant_id AND id=NEW.execution_id;
 SELECT * INTO STRICT v FROM api.task WHERE tenant_id=NEW.tenant_id AND id=e.task_id;
 IF NEW.port='command' THEN
  PERFORM api.prerequisites(NEW.tenant_id,coalesce(e.invocation,v.intent));
  NEW.payload:=NEW.payload||jsonb_build_object('invocation',coalesce(e.invocation,v.intent));
 END IF;
 IF NEW.port='receipt' THEN
  PERFORM api.require_fields(v.intent,ARRAY['supplier','delivery','line']);
  p:=jsonb_build_object('family','receiving','scope','tenant','identity',v.tenant_id,'key',jsonb_build_array(v.intent->>'supplier',v.intent->>'delivery',v.intent->>'line')::text,'policy','receiving-source@1');
  IF octet_length(p->>'key')>512 THEN RAISE EXCEPTION 'receiving identity too long'; END IF;
  claim_uuid:=pg_catalog.uuidv7(); claims:=jsonb_build_array(api.claim_manifest(claim_uuid,'ownership',p),api.claim_manifest(pg_catalog.uuidv7(),'settlement',p,claim_uuid)); work:='receipt';
 ELSIF v.semantic_policy IS NOT NULL AND NEW.port IN ('command','settlement') THEN
  p:=v.semantic_policy; work:=v.intent->'items'->0->>'key';
  IF NEW.port='command' THEN
   IF p->>'scope'='workflow' THEN
    SELECT o.id INTO membership FROM api.task_execution_output o JOIN api.task_execution pe ON (pe.tenant_id,pe.id)=(o.tenant_id,o.execution_id) JOIN api.task_execution_output_entity m ON (m.tenant_id,m.output_id)=(o.tenant_id,o.id) WHERE o.tenant_id=NEW.tenant_id AND pe.task_id=v.owner_task AND o.port='membership' AND m.role='owned-child' AND m.target_id=v.id ORDER BY o.accepted_order LIMIT 1;
    IF membership IS NULL THEN RAISE EXCEPTION 'accepted workflow membership required before command'; END IF;
   END IF;
   NEW.payload:=NEW.payload||jsonb_build_object('semantic_scope_basis',jsonb_build_object('membership_output',membership,'policy',p));
   SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=NEW.tenant_id AND id=(v.intent->'items'->0->>'source')::uuid;
   loc:=api.place(NEW.tenant_id,h.container_id);
   IF p->>'scope'='site' AND loc.site IS DISTINCT FROM p->>'admission_site' THEN RAISE EXCEPTION 'pinned site changed before authorization'; END IF;
   claims:=jsonb_build_array(api.claim_manifest(pg_catalog.uuidv7(),'ownership',p));
  ELSE
   SELECT * INTO STRICT own FROM api.task_execution_output_entity WHERE tenant_id=NEW.tenant_id AND output_id=(NEW.payload->>'command')::uuid AND role='semantic-claim' AND claim_phase='ownership';
   IF own.semantic_family IS DISTINCT FROM p->>'family' OR own.scope_kind IS DISTINCT FROM p->>'scope' OR own.scope_identity IS DISTINCT FROM p->>'identity' OR own.consequence_key IS DISTINCT FROM p->>'key' OR own.target_id<>v.id OR NOT EXISTS(SELECT 1 FROM api.task_execution_output WHERE tenant_id=NEW.tenant_id AND id=own.output_id AND execution_id=e.id AND port='command') THEN RAISE EXCEPTION 'settlement is not authorized by ownership'; END IF;
   NEW.payload:=NEW.payload||jsonb_build_object('semantic_ownership',own.claim_id);
   IF NEW.payload->>'outcome' IS DISTINCT FROM 'unknown' THEN claims:=jsonb_build_array(api.claim_manifest(pg_catalog.uuidv7(),'settlement',p,own.claim_id)); END IF;
  END IF;
 ELSE RETURN NEW;
 END IF;
 NEW.payload:=NEW.payload||jsonb_build_object('semantic_claims',claims,'semantic_work',work);
 RETURN NEW;
END $$;
CREATE TRIGGER zz_certify_effect BEFORE INSERT ON api.task_execution_output FOR EACH ROW EXECUTE FUNCTION api.certify_effect();
CREATE FUNCTION api.project_claims() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE c jsonb; task uuid; d jsonb;
BEGIN
 SELECT task_id INTO STRICT task FROM api.task_execution WHERE tenant_id=NEW.tenant_id AND id=NEW.execution_id;
 FOR c IN SELECT * FROM jsonb_array_elements(coalesce(NEW.payload->'semantic_claims','[]')) LOOP
  INSERT INTO api.task_execution_output_entity(tenant_id,output_id,member,role,target_type,target_id,selector,claim_id,claim_phase,semantic_family,scope_kind,scope_identity,consequence_key,policy_pin,ownership_id,ownership_phase)
  VALUES(NEW.tenant_id,NEW.id,NEW.payload->>'semantic_work','semantic-claim','task',task,c->>'phase',(c->>'id')::uuid,c->>'phase',c->>'family',c->>'scope',c->>'identity',c->>'key',c->>'policy',(c->>'owner')::uuid,CASE WHEN c->>'phase'='settlement' THEN 'ownership' END);
 END LOOP;
 IF NEW.port='command' THEN
  IF NEW.payload->'semantic_scope_basis'->>'membership_output' IS NOT NULL THEN PERFORM api.edge(NEW.tenant_id,NEW.id,NEW.payload->>'semantic_work','scope-membership','output',(NEW.payload->'semantic_scope_basis'->>'membership_output')::uuid); END IF;
  FOR d IN SELECT * FROM jsonb_array_elements(coalesce(NEW.payload->'invocation'->'dependencies','[]')) LOOP
   PERFORM api.edge(NEW.tenant_id,NEW.id,'input/'||coalesce(d->>'role','legacy'),'selected-output','output',(d->>'output')::uuid,coalesce(d->>'member',''));
   PERFORM api.edge(NEW.tenant_id,NEW.id,'input/'||coalesce(d->>'role','legacy'),'selected-execution','execution',(d->>'execution')::uuid);
  END LOOP;
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER project_claims AFTER INSERT ON api.task_execution_output FOR EACH ROW EXECUTE FUNCTION api.project_claims();
CREATE FUNCTION api.sealed_relationship() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM api.task_execution_output WHERE tenant_id=NEW.tenant_id AND id=NEW.output_id AND writer_xid=pg_current_xact_id()) THEN RAISE EXCEPTION 'accepted output relationship set is sealed'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER sealed_relationship BEFORE INSERT ON api.task_execution_output_entity FOR EACH ROW EXECUTE FUNCTION api.sealed_relationship();
CREATE FUNCTION api.claim_integrity() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE o api.task_execution_output; c jsonb; own api.task_execution_output_entity; e api.task_execution; n integer;
BEGIN
 IF TG_TABLE_NAME='task_execution_output' THEN o:=NEW;
 ELSE SELECT * INTO STRICT o FROM api.task_execution_output WHERE tenant_id=NEW.tenant_id AND id=NEW.output_id; END IF;
 SELECT * INTO STRICT e FROM api.task_execution WHERE tenant_id=o.tenant_id AND id=o.execution_id;
 SELECT count(*) INTO n FROM api.task_execution_output_entity WHERE tenant_id=o.tenant_id AND output_id=o.id AND role='semantic-claim';
 IF n<>jsonb_array_length(coalesce(o.payload->'semantic_claims','[]')) THEN RAISE EXCEPTION 'incomplete semantic claim extraction'; END IF;
 FOR c IN SELECT * FROM jsonb_array_elements(coalesce(o.payload->'semantic_claims','[]')) LOOP
  IF NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity q WHERE q.tenant_id=o.tenant_id AND q.output_id=o.id AND q.role='semantic-claim' AND q.member=o.payload->>'semantic_work' AND q.target_id=e.task_id AND q.claim_id=(c->>'id')::uuid AND api.claim_manifest(q.claim_id,q.claim_phase,jsonb_build_object('family',q.semantic_family,'scope',q.scope_kind,'identity',q.scope_identity,'key',q.consequence_key,'policy',q.policy_pin),q.ownership_id)=c) THEN RAISE EXCEPTION 'claim identity/projection mismatch'; END IF;
  IF c->>'phase'='ownership' AND o.port NOT IN ('command','receipt') THEN RAISE EXCEPTION 'ownership needs accepted authorization'; END IF;
  IF c->>'phase'='ownership' AND c->>'scope'='workflow' AND NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity basis JOIN api.task_execution_output membership ON (membership.tenant_id,membership.id)=(basis.tenant_id,basis.target_id) JOIN api.task_execution parent_execution ON (parent_execution.tenant_id,parent_execution.id)=(membership.tenant_id,membership.execution_id) WHERE basis.tenant_id=o.tenant_id AND basis.output_id=o.id AND basis.role='scope-membership' AND basis.target_type='output' AND basis.target_id=(o.payload->'semantic_scope_basis'->>'membership_output')::uuid AND membership.port='membership' AND parent_execution.task_id=(c->>'identity')::uuid) THEN RAISE EXCEPTION 'missing certified membership basis'; END IF;
  IF c->>'phase'='settlement' THEN
   SELECT * INTO STRICT own FROM api.task_execution_output_entity WHERE tenant_id=o.tenant_id AND claim_id=(c->>'owner')::uuid AND claim_phase='ownership';
   IF NOT EXISTS(SELECT 1 FROM api.task_execution_output z WHERE z.tenant_id=o.tenant_id AND z.id=own.output_id AND z.execution_id=o.execution_id AND (z.port='command' AND o.port='settlement' AND o.payload->>'command'=z.id::text OR z.id=o.id AND o.port='receipt')) THEN RAISE EXCEPTION 'settlement command/producer mismatch'; END IF;
  END IF;
 END LOOP;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER claim_integrity AFTER INSERT ON api.task_execution_output DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.claim_integrity();
CREATE CONSTRAINT TRIGGER claim_integrity AFTER INSERT ON api.task_execution_output_entity DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.claim_integrity();
-- Complete-set validation also runs on every relationship insertion, including
-- when a caller forces deferred constraints early within the transaction.
DO $$ DECLARE b text; BEGIN
 b:=pg_get_functiondef('api.workflow_output_integrity()'::regprocedure);
 b:=replace(b,'DECLARE w uuid;','DECLARE outrow api.task_execution_output; w uuid;');
 b:=replace(b,'NEW.','outrow.');
 b:=replace(b,'BEGIN
 IF outrow.spec_id','BEGIN
 IF TG_TABLE_NAME=''task_execution_output'' THEN outrow:=NEW;
 ELSE SELECT * INTO STRICT outrow FROM api.task_execution_output WHERE tenant_id=NEW.tenant_id AND id=NEW.output_id; END IF;
 IF outrow.spec_id');
 b:=replace(b,'IF outrow.port=''coordination'' THEN','IF outrow.port=''membership'' THEN
  SELECT intent->''members'' INTO STRICT facts FROM api.task WHERE tenant_id=outrow.tenant_id AND id=w;
  SELECT count(*) INTO n FROM api.task_execution_output_entity WHERE tenant_id=outrow.tenant_id AND output_id=outrow.id;
  IF outrow.payload->''members'' IS DISTINCT FROM facts OR n<>jsonb_array_length(facts) THEN RAISE EXCEPTION ''incomplete membership evidence''; END IF;
  FOR f IN SELECT * FROM jsonb_array_elements(facts) LOOP
   IF NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=outrow.tenant_id AND output_id=outrow.id AND member=f->>''name'' AND role=''owned-child'' AND target_type=''task'' AND target_id=(f->>''task'')::uuid AND selector=f->>''role'') THEN RAISE EXCEPTION ''wrong membership evidence''; END IF;
  END LOOP;
 END IF;
 IF outrow.port=''coordination'' THEN');
 EXECUTE b;
END $$;
CREATE CONSTRAINT TRIGGER workflow_relationship_integrity AFTER INSERT ON api.task_execution_output_entity DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.workflow_output_integrity();
NOTIFY pgrst,'reload schema';
COMMIT;
