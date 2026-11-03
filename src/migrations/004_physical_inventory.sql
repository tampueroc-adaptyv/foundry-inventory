\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
-- Finite, retained contracts. No user publication or executable JSON interpreter.
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['a','b'] LOOP
 INSERT INTO api.material_spec_catalog(tenant_id,id,version,handler,definition) VALUES
 (t,'purchased-powder@1',1,'v1','{"dimension":"mass","identity":"new-preparation","uses":["transfer","reconstitute"]}'),
 (t,'reconstituted@1',1,'v1','{"dimension":"volume","identity":"new-preparation","uses":["transfer","consume"],"method":"reconstitute@1"}');
 INSERT INTO api.container_spec_catalog(tenant_id,id,version,handler,definition) VALUES
 (t,'rack@1',1,'v1','{"children":["tube@1","plate384@1","rack@1"],"slots":24,"direct_material":false}');
 INSERT INTO api.task_spec_catalog(tenant_id,id,version,handler,definition) VALUES
 (t,'inventory-register@1',1,'v1','{"kind":"registration","ports":["registration","terminal"],"required_ports":["registration"]}'),
 (t,'reconstitute@1',1,'v1','{"kind":"reconstitution","ports":["command","settlement","terminal"],"required_ports":["command","settlement"],"physical":true,"recovery_phases":["input","output","unknown","zero"]}'),
 (t,'consume@1',1,'v1','{"kind":"consumption","ports":["command","settlement","terminal"],"required_ports":["command","settlement"],"physical":true,"recovery_phases":["consume","unknown","zero"]}'),
 (t,'dispose@1',1,'v1','{"kind":"disposal","ports":["command","settlement","terminal"],"required_ports":["command","settlement"],"physical":true,"recovery_phases":["dispose","unknown","zero"]}'),
 (t,'relocate@1',1,'v1','{"kind":"relocation","ports":["command","settlement","terminal"],"required_ports":["command","settlement"],"physical":true,"recovery_phases":["move","unknown","zero"]}');
 END LOOP;
END $$;
ALTER TABLE api.container ADD COLUMN placement_output uuid;
ALTER TABLE api.container ADD FOREIGN KEY(tenant_id,placement_output) REFERENCES api.task_execution_output(tenant_id,id);
ALTER TABLE api.container ADD FOREIGN KEY(tenant_id,created_output) REFERENCES api.task_execution_output(tenant_id,id);
ALTER TABLE api.material ADD FOREIGN KEY(tenant_id,created_output) REFERENCES api.task_execution_output(tenant_id,id);
ALTER TABLE api.container_content ADD FOREIGN KEY(tenant_id,created_output) REFERENCES api.task_execution_output(tenant_id,id);
CREATE UNIQUE INDEX occupied_location_slot ON api.container(tenant_id,location_id,position) WHERE location_id IS NOT NULL AND position IS NOT NULL;

CREATE FUNCTION api.pending_output(t text,o uuid,work text) RETURNS boolean LANGUAGE sql STABLE SET search_path=pg_catalog,api AS $$
 SELECT NOT EXISTS(SELECT 1 FROM api.task_execution_output z JOIN api.task_execution_output_entity st ON st.tenant_id=z.tenant_id AND st.output_id=z.id
 WHERE z.tenant_id=t AND z.port='settlement' AND z.payload->>'command'=o::text AND st.role='settlement' AND st.selector=work)
$$;
CREATE FUNCTION api.descendants(t text,c uuid) RETURNS uuid[] LANGUAGE sql STABLE SET search_path=pg_catalog,api AS $$
 WITH RECURSIVE d(id,path) AS (SELECT c,ARRAY[c] UNION ALL SELECT ch.id,d.path||ch.id FROM api.container ch JOIN d ON ch.parent_id=d.id WHERE ch.tenant_id=t AND NOT ch.id=ANY(d.path)) SELECT array_agg(id) FROM d
$$;
CREATE FUNCTION api.assert_container_free(t text,c uuid) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE sub uuid[]; ancestors uuid[]; BEGIN
 PERFORM 1 FROM api.container WHERE tenant_id=t AND id=c; IF NOT FOUND THEN RAISE EXCEPTION 'invalid tenant container'; END IF;
 sub:=api.descendants(t,c);
 WITH RECURSIVE a(id,parent_id,path) AS (SELECT id,parent_id,ARRAY[id] FROM api.container WHERE tenant_id=t AND id=c UNION ALL SELECT p.id,p.parent_id,a.path||p.id FROM api.container p JOIN a ON p.id=a.parent_id WHERE p.tenant_id=t AND NOT p.id=ANY(a.path)) SELECT array_agg(id) INTO ancestors FROM a;
 IF EXISTS(SELECT 1 FROM api.task_execution_output_entity r WHERE r.tenant_id=t AND api.pending_output(t,r.output_id,r.member) AND (
 (r.role='container-resource' AND r.target_id=ANY(sub||ancestors)) OR
 (r.role='resource' AND r.target_id IN(SELECT id FROM api.container_content WHERE tenant_id=t AND container_id=ANY(sub))))) THEN RAISE EXCEPTION 'unresolved physical container scope'; END IF;
END $$;
CREATE FUNCTION api.assert_holding_free(t text,h uuid) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE c uuid; BEGIN
 SELECT container_id INTO STRICT c FROM api.container_content WHERE tenant_id=t AND id=h;
 PERFORM api.assert_container_free(t,c);
END $$;
CREATE FUNCTION api.physical_edge(t text,o uuid,member text,role text,typ text,target uuid,selector text DEFAULT '') RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
BEGIN
 IF typ='location' THEN
 IF NOT EXISTS(SELECT 1 FROM api.location WHERE tenant_id=t AND id=target) THEN RAISE EXCEPTION 'invalid tenant location'; END IF;
 INSERT INTO api.task_execution_output_entity VALUES(t,o,member,role,typ,target,selector);
 ELSE PERFORM api.edge(t,o,member,role,typ,target,selector); END IF;
END $$;
CREATE FUNCTION api.placement_destination(t text,child uuid,child_spec text,parent uuid,loc uuid,pos text,wc text) RETURNS api.location LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE p api.container; l api.location; BEGIN
 IF num_nonnulls(parent,loc)<>1 OR pos IS NULL OR pos !~ '^[A-Za-z0-9_-]{1,32}$' THEN RAISE EXCEPTION 'one parent/location and explicit position required'; END IF;
 IF parent IS NOT NULL THEN
 SELECT * INTO STRICT p FROM api.container WHERE tenant_id=t AND id=parent;
 IF p.spec_id<>'rack@1' OR child_spec NOT IN ('tube@1','plate384@1','rack@1') OR pos !~ '^S(0[1-9]|1[0-9]|2[0-4])$' THEN RAISE EXCEPTION 'incompatible parent or position'; END IF;
 IF child IS NOT NULL AND parent=ANY(api.descendants(t,child)) THEN RAISE EXCEPTION 'container ancestry cycle'; END IF;
 PERFORM api.assert_container_free(t,parent);
 l:=api.place(t,parent);
 ELSE
 SELECT * INTO STRICT l FROM api.location WHERE tenant_id=t AND id=loc;
 IF l.spec_id<>'lab@1' THEN RAISE EXCEPTION 'unsupported location compatibility'; END IF;
 END IF;
 IF l.workcell IS NULL OR NOT EXISTS(SELECT 1 FROM api.location WHERE tenant_id=t AND workcell=wc) THEN RAISE EXCEPTION 'workcell not authorized'; END IF;
 IF EXISTS(SELECT 1 FROM api.container c WHERE c.tenant_id=t AND c.id IS DISTINCT FROM child AND c.position=pos AND ((parent IS NOT NULL AND c.parent_id=parent) OR (loc IS NOT NULL AND c.location_id=loc))) THEN RAISE EXCEPTION 'occupied placement position'; END IF;
 IF EXISTS(SELECT 1 FROM api.task_execution_output_entity r WHERE r.tenant_id=t AND r.role='placement-destination' AND r.target_id=coalesce(parent,loc) AND r.selector=pos AND api.pending_output(t,r.output_id,r.member)) THEN RAISE EXCEPTION 'pending placement destination'; END IF;
 RETURN l;
END $$;
CREATE FUNCTION api.physical_quantity(q numeric,u text,d text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE n numeric; BEGIN
 n:=api.normalized(q,u,d); IF n IS NULL OR n<=0 THEN RAISE EXCEPTION 'positive exact quantity required'; END IF; RETURN n;
END $$;
CREATE FUNCTION api.physical_eligible(t text,h uuid,q numeric,purpose text) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE policy jsonb; BEGIN
 SELECT s.definition INTO STRICT policy FROM api.container_content cc JOIN api.material m ON (m.tenant_id,m.id)=(cc.tenant_id,cc.material_id) JOIN api.material_spec_catalog s ON (s.tenant_id,s.id)=(m.tenant_id,m.spec_id) WHERE cc.tenant_id=t AND cc.id=h;
 IF NOT coalesce(policy->'uses' ? purpose,false) THEN RAISE EXCEPTION 'unsupported intended physical use'; END IF;
 -- The finite new policies use the same physical/QC checks as transfer, not binding-fit approval.
 IF api.usability(h,q,'transfer')->>'status'<>'Yes' THEN RAISE EXCEPTION 'material not currently usable'; END IF;
END $$;
CREATE FUNCTION api.validate_inventory_intent(t text,spec text,i jsonb,wc text) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE h api.container_content; c api.container; l api.location; dl api.location; d text; allowed text[]; BEGIN
 IF jsonb_typeof(i) IS DISTINCT FROM 'object' OR NOT EXISTS(SELECT 1 FROM api.location WHERE tenant_id=t AND workcell=wc) THEN RAISE EXCEPTION 'invalid intent/workcell'; END IF;
 allowed:=CASE spec WHEN 'inventory-register@1' THEN ARRAY['operation','spec','barcode','parent','location','position','container','material','material_spec','label','supplier_identity'] WHEN 'relocate@1' THEN ARRAY['container','parent','location','position','expected_seq'] WHEN 'reconstitute@1' THEN ARRAY['source','destination','quantity','unit','output_quantity','output_unit','method','reason','label'] ELSE ARRAY['source','quantity','unit','reason'] END;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(i) AS key(value) WHERE NOT key.value=ANY(allowed||ARRAY['items'])) THEN RAISE EXCEPTION 'unsupported governed inventory input'; END IF;
 IF spec='inventory-register@1' THEN
 IF i->>'operation'='container' THEN
 IF i->>'spec' IS NULL OR i->>'spec' NOT IN ('tube@1','plate384@1','rack@1') OR coalesce(i->>'barcode','')='' THEN RAISE EXCEPTION 'unsupported container registration'; END IF;
 l:=api.placement_destination(t,NULL,i->>'spec',(i->>'parent')::uuid,(i->>'location')::uuid,i->>'position',wc);
 IF l.workcell<>wc THEN RAISE EXCEPTION 'wrong registration workcell'; END IF;
 ELSIF i->>'operation' IN ('stock','holding') THEN
 SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'container')::uuid;
 IF c.spec_id NOT IN ('tube@1','well@1') THEN RAISE EXCEPTION 'container cannot directly hold material'; END IF;
 PERFORM api.assert_container_free(t,c.id);
 l:=api.place(t,c.id); IF l.workcell<>wc THEN RAISE EXCEPTION 'wrong registration workcell'; END IF;
 IF EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=t AND container_id=c.id AND NOT closed) THEN RAISE EXCEPTION 'direct container already occupied'; END IF;
 IF i->>'operation'='stock' THEN
 IF i->>'material_spec' IS DISTINCT FROM 'purchased-powder@1' OR coalesce(i->>'label','')='' OR jsonb_typeof(i->'supplier_identity') IS DISTINCT FROM 'object' OR coalesce(i->'supplier_identity'->>'supplier','')='' OR coalesce(i->'supplier_identity'->>'lot','')='' THEN RAISE EXCEPTION 'supported purchased identity/lot required'; END IF;
 ELSE
 SELECT s.definition->>'dimension' INTO STRICT d FROM api.material m JOIN api.material_spec_catalog s ON (s.tenant_id,s.id)=(m.tenant_id,m.spec_id) WHERE m.tenant_id=t AND m.id=(i->>'material')::uuid;
 IF d NOT IN ('mass','volume','count') OR d IS NULL THEN RAISE EXCEPTION 'unsupported accounting dimension'; END IF;
 END IF;
 ELSE RAISE EXCEPTION 'unsupported registration operation'; END IF;
 ELSIF spec IN ('reconstitute@1','consume@1','dispose@1') THEN
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(i->>'source')::uuid AND NOT closed;
 PERFORM api.physical_quantity((i->>'quantity')::numeric,i->>'unit',h.dimension);
 IF coalesce(i->>'reason','')='' THEN RAISE EXCEPTION 'physical purpose/reason required'; END IF;
 l:=api.place(t,h.container_id); IF l.workcell<>wc THEN RAISE EXCEPTION 'wrong physical workcell'; END IF;
 IF spec='reconstitute@1' THEN
 IF i->>'method' IS DISTINCT FROM 'reconstitute@1' OR NOT EXISTS(SELECT 1 FROM api.material WHERE tenant_id=t AND id=h.material_id AND spec_id='purchased-powder@1') THEN RAISE EXCEPTION 'unsupported transformation or source specification'; END IF;
 SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'destination')::uuid;
 IF c.spec_id NOT IN ('tube@1','well@1') OR c.id=h.container_id OR EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=t AND container_id=c.id AND NOT closed) THEN RAISE EXCEPTION 'empty compatible preparation destination required'; END IF;
 dl:=api.place(t,c.id); IF dl.site<>l.site OR dl.workcell<>wc THEN RAISE EXCEPTION 'preparation site/workcell violation'; END IF;
 PERFORM api.physical_quantity((i->>'output_quantity')::numeric,i->>'output_unit','volume');
 END IF;
 ELSIF spec='relocate@1' THEN
 SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'container')::uuid;
 IF c.fixed THEN RAISE EXCEPTION 'fixed well cannot be independently relocated'; END IF;
 IF c.spec_id NOT IN ('tube@1','plate384@1','rack@1') OR i->>'expected_seq' IS NULL OR c.placement_seq<>(i->>'expected_seq')::bigint THEN RAISE EXCEPTION 'placement predecessor mismatch'; END IF;
 l:=api.place(t,c.id); IF l.workcell<>wc THEN RAISE EXCEPTION 'wrong relocation workcell'; END IF;
 dl:=api.placement_destination(t,c.id,c.spec_id,(i->>'parent')::uuid,(i->>'location')::uuid,i->>'position',wc);
 IF dl.site<>l.site THEN RAISE EXCEPTION 'local relocation cannot cross sites'; END IF;
 ELSE RAISE EXCEPTION 'unsupported physical specification'; END IF;
END $$;
CREATE FUNCTION api.open_inventory_task(spec text,request_key text,intent jsonb,workcell text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); v api.task; e api.task_execution; frozen jsonb; keys jsonb; BEGIN
 IF spec NOT IN ('inventory-register@1','reconstitute@1','consume@1','dispose@1','relocate@1') OR spec IS NULL THEN RAISE EXCEPTION 'unsupported inventory handler version'; END IF;
 keys:=CASE spec WHEN 'inventory-register@1' THEN '[]'::jsonb WHEN 'reconstitute@1' THEN '[{"key":"input"},{"key":"output"}]'::jsonb WHEN 'relocate@1' THEN '[{"key":"move"}]'::jsonb ELSE '[{"key":"use"}]'::jsonb END;
 IF intent ? 'items' THEN RAISE EXCEPTION 'work keys are server-owned'; END IF;
 frozen:=intent||jsonb_build_object('items',keys);
 SELECT * INTO v FROM api.task WHERE tenant_id=t AND task.request_key=open_inventory_task.request_key;
 IF FOUND THEN
 SELECT * INTO STRICT e FROM api.task_execution WHERE tenant_id=t AND task_id=v.id AND attempt=1;
 IF v.spec_id<>spec OR v.intent<>frozen OR e.workcell<>workcell THEN RAISE EXCEPTION 'conflicting inventory task retry'; END IF; RETURN e.id;
 END IF;
 PERFORM api.validate_inventory_intent(t,spec,intent,workcell);
 INSERT INTO api.task(tenant_id,spec_id,request_key,intent) VALUES(t,spec,request_key,frozen) RETURNING * INTO v;
 INSERT INTO api.task_execution(tenant_id,task_id,spec_id,attempt,workcell) VALUES(t,v.id,spec,1,workcell) RETURNING id INTO e.id;
 RETURN e.id;
END $$;

CREATE FUNCTION api.inventory_accept(execution uuid,request_key text,phase text,payload jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); e api.task_execution; v api.task; old api.task_execution_output; cmd api.task_execution_output; input_o api.task_execution_output;
 o uuid:=gen_random_uuid(); req jsonb:=jsonb_build_object('phase',phase,'payload',payload); p jsonb; port text; i jsonb; contract jsonb;
 h api.container_content; c api.container; l api.location; mat api.material; input_m api.material_movement;
 mid uuid:=gen_random_uuid(); hid uuid:=gen_random_uuid(); cid uuid:=gen_random_uuid(); movement uuid; work text; q numeric; entered numeric; unit text; dim text; x jsonb; wells jsonb:='[]'; j integer; wid uuid; name text;
BEGIN
 SELECT * INTO STRICT e FROM api.task_execution WHERE tenant_id=t AND id=execution;
 SELECT * INTO STRICT v FROM api.task WHERE tenant_id=t AND id=e.task_id;
 IF e.spec_id NOT IN ('inventory-register@1','reconstitute@1','consume@1','dispose@1','relocate@1') THEN RAISE EXCEPTION 'not an inventory execution'; END IF;
 SELECT * INTO old FROM api.task_execution_output WHERE tenant_id=t AND execution_id=execution AND task_execution_output.request_key=inventory_accept.request_key;
 IF FOUND THEN IF old.request<>req THEN RAISE EXCEPTION 'conflicting inventory acceptance retry'; END IF; RETURN old.id; END IF;
 IF phase IS NULL OR jsonb_typeof(payload) IS DISTINCT FROM 'object' OR coalesce(payload->>'evidence','')='' THEN RAISE EXCEPTION 'governed physical evidence required'; END IF;
 SELECT definition INTO STRICT contract FROM api.task_spec_catalog WHERE tenant_id=t AND id=e.spec_id;
 IF e.state<>'Running' AND NOT coalesce(contract->'recovery_phases' ? phase,false) THEN RAISE EXCEPTION 'terminal execution does not permit this operation'; END IF;
 i:=v.intent; p:=payload||jsonb_build_object('phase',phase,'intent',i,'task',v.id,'spec',e.spec_id);
 IF phase='register' THEN
 IF e.spec_id<>'inventory-register@1' OR payload->>'confirmed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'confirmed registration required'; END IF;
 PERFORM api.validate_inventory_intent(t,e.spec_id,i,e.workcell);
 IF EXISTS(SELECT 1 FROM api.task_execution_output WHERE tenant_id=t AND execution_id=execution AND task_execution_output.port='registration') THEN RAISE EXCEPTION 'registration already accepted'; END IF;
 port:='registration';
 IF i->>'operation'='container' THEN
 IF i->>'spec'='plate384@1' THEN
 FOR j IN 1..384 LOOP
 name:=chr(65+(j-1)/24)||lpad((((j-1)%24)+1)::text,2,'0'); wells:=wells||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'position',name));
 END LOOP; END IF;
 p:=p||jsonb_build_object('container',cid,'wells',wells);
 ELSE
 IF i->>'operation'='holding' THEN mid:=(i->>'material')::uuid; END IF;
 p:=p||jsonb_build_object('material',mid,'holding',hid,'identity_decision',CASE WHEN i->>'operation'='stock' THEN 'Create' ELSE 'Reuse' END);
 END IF;
 ELSIF phase='command' THEN
 IF e.spec_id='inventory-register@1' OR payload->>'protocol' IS DISTINCT FROM 'external-fence-v1' OR coalesce(payload->>'command_id','')='' THEN RAISE EXCEPTION 'unique fenced command identity required'; END IF;
 PERFORM api.validate_inventory_intent(t,e.spec_id,i,e.workcell);
 IF e.spec_id='relocate@1' THEN
 PERFORM api.assert_container_free(t,(i->>'container')::uuid);
 ELSE
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(i->>'source')::uuid;
 PERFORM api.assert_holding_free(t,h.id); q:=api.physical_quantity((i->>'quantity')::numeric,i->>'unit',h.dimension);
 IF e.spec_id='dispose@1' THEN
 IF NOT EXISTS(SELECT 1 FROM api.material_balance WHERE tenant_id=t AND holding_id=h.id AND amount>=q) THEN RAISE EXCEPTION 'insufficient disposal stock'; END IF;
 ELSE PERFORM api.physical_eligible(t,h.id,q,CASE WHEN e.spec_id='consume@1' THEN 'consume' ELSE 'reconstitute' END); END IF;
 IF e.spec_id='reconstitute@1' THEN PERFORM api.assert_container_free(t,(i->>'destination')::uuid); END IF;
 END IF;
 port:='command';
 ELSE
 IF phase NOT IN ('input','output','consume','dispose','move','unknown','zero') OR e.spec_id='inventory-register@1' THEN RAISE EXCEPTION 'unsupported physical outcome'; END IF;
 SELECT * INTO STRICT cmd FROM api.task_execution_output WHERE tenant_id=t AND id=(payload->>'command')::uuid AND execution_id=execution AND task_execution_output.port='command';
 work:=CASE phase WHEN 'input' THEN 'input' WHEN 'output' THEN 'output' WHEN 'move' THEN 'move' WHEN 'consume' THEN 'use' WHEN 'dispose' THEN 'use' ELSE payload->>'work' END;
 IF work IS NULL OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(i->'items') AS item(value) WHERE item.value->>'key'=work) THEN RAISE EXCEPTION 'invalid physical work key'; END IF;
 IF (phase IN ('input','output') AND e.spec_id<>'reconstitute@1') OR (phase='consume' AND e.spec_id<>'consume@1') OR (phase='dispose' AND e.spec_id<>'dispose@1') OR (phase='move' AND e.spec_id<>'relocate@1') THEN RAISE EXCEPTION 'operation/phase mismatch'; END IF;
 IF NOT api.pending_output(t,cmd.id,work) THEN RAISE EXCEPTION 'physical work already settled'; END IF;
 port:='settlement'; p:=p||jsonb_build_object('work',work,'command',cmd.id);
 IF payload->>'outcome' IS DISTINCT FROM (CASE phase WHEN 'unknown' THEN 'unknown' WHEN 'zero' THEN 'zero' ELSE 'confirmed' END) THEN RAISE EXCEPTION 'explicit physical outcome required'; END IF;
 IF phase<>'unknown' THEN
 IF payload->>'confirmed' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'explicit independent confirmation required'; END IF;
 IF payload->>'fence_retired' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'positive command retirement required'; END IF;
 IF phase='zero' THEN
 IF payload->>'quantity' IS DISTINCT FROM '0' THEN RAISE EXCEPTION 'explicit evidenced zero required'; END IF;
 ELSIF phase='move' THEN
 -- Recheck frozen predecessor/topology but ignore our own pending resource claim.
 SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'container')::uuid;
 IF c.fixed OR c.placement_seq<>(i->>'expected_seq')::bigint THEN RAISE EXCEPTION 'placement predecessor changed'; END IF;
 p:=p||jsonb_build_object('before',jsonb_build_object('parent',c.parent_id,'location',c.location_id,'position',c.position,'seq',c.placement_seq,'effective_at',c.effective_at),'after',jsonb_build_object('parent',(i->>'parent')::uuid,'location',(i->>'location')::uuid,'position',i->>'position','seq',c.placement_seq+1),'effective_at',greatest(clock_timestamp(),c.effective_at));
 ELSE
 IF phase='output' THEN
 SELECT z.* INTO STRICT input_o FROM api.task_execution_output z JOIN api.material_movement mm ON (mm.tenant_id,mm.output_id)=(z.tenant_id,z.id) WHERE z.tenant_id=t AND z.execution_id=execution AND z.payload->>'phase'='input' AND mm.kind='consumption';
 SELECT * INTO STRICT input_m FROM api.material_movement WHERE tenant_id=t AND output_id=input_o.id;
 dim:='volume'; unit:=payload->>'unit'; entered:=(payload->>'quantity')::numeric;
 q:=api.physical_quantity(entered,unit,dim);
 IF q>api.physical_quantity((i->>'output_quantity')::numeric,i->>'output_unit',dim) THEN RAISE EXCEPTION 'output exceeds confirmed command scope'; END IF;
 SELECT * INTO STRICT c FROM api.container WHERE tenant_id=t AND id=(i->>'destination')::uuid;
 IF EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=t AND container_id=c.id AND NOT closed) THEN RAISE EXCEPTION 'preparation destination occupied'; END IF;
 p:=p||jsonb_build_object('material',mid,'holding',hid,'identity_decision','Create','material_spec','reconstituted@1','input_output',input_o.id,'input_material',input_m.material_id,'input_quantity',input_o.payload->'normalized_quantity','input_spec','purchased-powder@1');
 ELSE
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(i->>'source')::uuid;
 SELECT * INTO STRICT mat FROM api.material WHERE tenant_id=t AND id=h.material_id;
 dim:=h.dimension; entered:=(payload->>'quantity')::numeric; unit:=payload->>'unit'; q:=api.physical_quantity(entered,unit,dim);
 IF q>api.physical_quantity((i->>'quantity')::numeric,i->>'unit',dim) THEN RAISE EXCEPTION 'effect exceeds command scope'; END IF;
 p:=p||jsonb_build_object('source_material',h.material_id,'source_holding',h.id,'source_spec',mat.spec_id);
 END IF;
 p:=p||jsonb_build_object('normalized_quantity',q,'dimension',dim,'normalization','units@1');
 END IF;
 END IF;
 END IF;
 INSERT INTO api.task_execution_output(tenant_id,id,execution_id,spec_id,request_key,port,request,payload,actor) VALUES(t,o,execution,e.spec_id,request_key,port,req,p,current_setting('role'));
 IF phase='register' THEN
 PERFORM api.edge(t,o,'registration','settlement','task',v.id,'registration');
 IF i->>'operation'='container' THEN
 INSERT INTO api.container(tenant_id,id,spec_id,barcode,parent_id,location_id,position,created_output) VALUES(t,cid,i->>'spec',i->>'barcode',(i->>'parent')::uuid,(i->>'location')::uuid,i->>'position',o);
 PERFORM api.edge(t,o,'container','created-container','container',cid);
 FOR x IN SELECT * FROM jsonb_array_elements(wells) LOOP
 INSERT INTO api.container(tenant_id,id,spec_id,parent_id,position,fixed,created_output) VALUES(t,(x->>'id')::uuid,'well@1',cid,x->>'position',true,o);
 PERFORM api.edge(t,o,x->>'position','created-well','container',(x->>'id')::uuid);
 END LOOP;
 ELSE
 IF i->>'operation'='stock' THEN
 INSERT INTO api.material(tenant_id,id,spec_id,label,identity,created_output) VALUES(t,mid,'purchased-powder@1',i->>'label',i->'supplier_identity',o); dim:='mass';
 ELSE SELECT s.definition->>'dimension' INTO dim FROM api.material m JOIN api.material_spec_catalog s ON (s.tenant_id,s.id)=(m.tenant_id,m.spec_id) WHERE m.tenant_id=t AND m.id=mid; END IF;
 INSERT INTO api.container_content(tenant_id,id,material_id,container_id,dimension,created_output) VALUES(t,hid,mid,(i->>'container')::uuid,dim,o);
 PERFORM api.edge(t,o,'holding','registered-holding','holding',hid); PERFORM api.edge(t,o,'holding','identity-material','material',mid);
 END IF;
 ELSIF phase='command' THEN
 IF e.spec_id='relocate@1' THEN
 PERFORM api.edge(t,o,'move','command','task',v.id,'move');
 PERFORM api.edge(t,o,'move','container-resource','container',(i->>'container')::uuid);
 FOR h IN SELECT * FROM api.container_content WHERE tenant_id=t AND container_id=ANY(api.descendants(t,(i->>'container')::uuid)) LOOP PERFORM api.edge(t,o,'move','resource','holding',h.id); END LOOP;
 PERFORM api.physical_edge(t,o,'move','placement-destination',CASE WHEN i->>'parent' IS NULL THEN 'location' ELSE 'container' END,coalesce((i->>'parent')::uuid,(i->>'location')::uuid),i->>'position');
 IF i->>'parent' IS NOT NULL THEN PERFORM api.edge(t,o,'move','container-resource','container',(i->>'parent')::uuid); END IF;
 ELSE
 work:=CASE WHEN e.spec_id='reconstitute@1' THEN 'input' ELSE 'use' END;
 PERFORM api.edge(t,o,work,'command','task',v.id,work); PERFORM api.edge(t,o,work,'resource','holding',(i->>'source')::uuid);
 IF e.spec_id='reconstitute@1' THEN
 PERFORM api.edge(t,o,'output','command','task',v.id,'output'); PERFORM api.edge(t,o,'output','container-resource','container',(i->>'destination')::uuid);
 END IF;
 END IF;
 ELSE
 PERFORM api.edge(t,o,work,'command-basis','output',cmd.id);
 IF phase<>'unknown' THEN
 PERFORM api.edge(t,o,work,'settlement','task',v.id,work);
 IF phase='move' THEN
 UPDATE api.container SET parent_id=(i->>'parent')::uuid,location_id=(i->>'location')::uuid,position=i->>'position',placement_seq=placement_seq+1,effective_at=(p->>'effective_at')::timestamptz,placement_output=o WHERE tenant_id=t AND id=c.id;
 PERFORM api.edge(t,o,'move','relocated-container','container',c.id);
 ELSIF phase='output' THEN
 INSERT INTO api.material(tenant_id,id,spec_id,label,identity,created_output) VALUES(t,mid,'reconstituted@1',coalesce(i->>'label','reconstituted preparation'),jsonb_build_object('method','reconstitute@1','source_material',input_m.material_id,'source_holding',i->>'source','input_output',input_o.id,'input_quantity',input_o.payload->'normalized_quantity','output_quantity',q,'input_spec','purchased-powder@1'),o);
 INSERT INTO api.container_content(tenant_id,id,material_id,container_id,dimension,created_output) VALUES(t,hid,mid,(i->>'destination')::uuid,'volume',o);
 INSERT INTO api.material_movement(tenant_id,output_id,member,material_id,dimension,kind) VALUES(t,o,'output',mid,'volume','production') RETURNING id INTO movement;
 PERFORM api.post(t,movement,NULL,'production',-entered,unit); PERFORM api.post(t,movement,hid,NULL,entered,unit);
 PERFORM api.edge(t,o,'output','produced-material','material',mid); PERFORM api.edge(t,o,'output','produced-holding','holding',hid);
 PERFORM api.edge(t,o,'output','source-material','material',input_m.material_id); PERFORM api.edge(t,o,'output','source-holding','holding',(i->>'source')::uuid); PERFORM api.edge(t,o,'output','input-acceptance','output',input_o.id);
 ELSIF phase<>'zero' THEN
 INSERT INTO api.material_movement(tenant_id,output_id,member,material_id,dimension,kind) VALUES(t,o,work,h.material_id,h.dimension,CASE WHEN phase='dispose' THEN 'disposal' ELSE 'consumption' END) RETURNING id INTO movement;
 PERFORM api.post(t,movement,h.id,NULL,-entered,unit); PERFORM api.post(t,movement,NULL,CASE WHEN phase='dispose' THEN 'disposal' ELSE 'consumption' END,entered,unit);
 PERFORM api.edge(t,o,work,'source-material','material',h.material_id); PERFORM api.edge(t,o,work,'source-holding','holding',h.id);
 END IF;
 END IF;
 END IF;
 RETURN o;
END $$;

CREATE FUNCTION api.physical_completion() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,api AS $$
DECLARE v api.task; BEGIN
 IF NEW.port<>'terminal' OR NEW.payload->>'state'<>'Completed' OR NEW.spec_id NOT IN ('reconstitute@1','consume@1','dispose@1','relocate@1') THEN RETURN NULL; END IF;
 SELECT t.* INTO STRICT v FROM api.task t JOIN api.task_execution e ON (e.tenant_id,e.task_id)=(t.tenant_id,t.id) WHERE e.tenant_id=NEW.tenant_id AND e.id=NEW.execution_id;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(v.intent->'items') j WHERE NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity st WHERE st.tenant_id=NEW.tenant_id AND st.role='settlement' AND st.target_id=v.id AND st.selector=j->>'key')) THEN RAISE EXCEPTION 'unresolved mandatory physical work'; END IF;
 IF NEW.spec_id='reconstitute@1' AND NOT EXISTS(SELECT 1 FROM api.material_movement m JOIN api.task_execution_output o ON (o.tenant_id,o.id)=(m.tenant_id,m.output_id) WHERE o.tenant_id=NEW.tenant_id AND o.execution_id=NEW.execution_id AND m.kind='production') THEN RAISE EXCEPTION 'confirmed preparation output missing'; END IF;
 IF NEW.spec_id IN ('consume@1','dispose@1') AND NOT EXISTS(SELECT 1 FROM api.material_movement m JOIN api.task_execution_output o ON (o.tenant_id,o.id)=(m.tenant_id,m.output_id) WHERE o.tenant_id=NEW.tenant_id AND o.execution_id=NEW.execution_id AND m.kind=CASE WHEN NEW.spec_id='consume@1' THEN 'consumption' ELSE 'disposal' END) THEN RAISE EXCEPTION 'confirmed withdrawal missing'; END IF;
 IF NEW.spec_id='relocate@1' AND NOT EXISTS(SELECT 1 FROM api.task_execution_output WHERE tenant_id=NEW.tenant_id AND execution_id=NEW.execution_id AND payload->>'phase'='move') THEN RAISE EXCEPTION 'confirmed relocation missing'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER physical_completion AFTER INSERT ON api.task_execution_output DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.physical_completion();
-- Receipts and closure must not bypass the physical scope established by new commands.
CREATE FUNCTION api.physical_legacy_boundary() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,api AS $$
DECLARE e api.task_execution; v api.task; h api.container_content; m api.material; l api.location; BEGIN
 IF NEW.port='receipt' OR (NEW.port='correction' AND NEW.payload->>'type'='close_holding') THEN
 SELECT * INTO STRICT e FROM api.task_execution WHERE tenant_id=NEW.tenant_id AND id=NEW.execution_id;
 SELECT * INTO STRICT v FROM api.task WHERE tenant_id=NEW.tenant_id AND id=e.task_id;
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=NEW.tenant_id AND id=CASE WHEN NEW.port='receipt' THEN (v.intent->>'holding')::uuid ELSE (NEW.payload->>'holding')::uuid END;
 PERFORM api.assert_holding_free(NEW.tenant_id,h.id);
 l:=api.place(NEW.tenant_id,h.container_id); IF l.workcell<>e.workcell THEN RAISE EXCEPTION 'wrong receipt/closure workcell'; END IF;
 SELECT * INTO STRICT m FROM api.material WHERE tenant_id=NEW.tenant_id AND id=h.material_id;
 IF NEW.port='receipt' AND m.spec_id='purchased-powder@1' AND (m.identity->>'supplier' IS DISTINCT FROM v.intent->>'supplier' OR m.identity->>'lot' IS DISTINCT FROM v.intent->>'lot') THEN RAISE EXCEPTION 'receipt does not match pinned supplier preparation identity'; END IF;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER physical_legacy_boundary BEFORE INSERT ON api.task_execution_output FOR EACH ROW EXECUTE FUNCTION api.physical_legacy_boundary();
CREATE FUNCTION api.physical_projection_integrity() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,api AS $$
DECLARE n integer; ph text:=NEW.payload->>'phase'; BEGIN
 IF NEW.spec_id NOT IN ('inventory-register@1','reconstitute@1','consume@1','dispose@1','relocate@1') THEN RETURN NULL; END IF;
 SELECT count(*) INTO n FROM api.material_movement WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id;
 IF ph IN ('input','output','consume','dispose') AND n<>1 THEN RAISE EXCEPTION 'mandatory physical movement missing'; END IF;
 IF ph IN ('register','command','unknown','zero','move') AND n<>0 THEN RAISE EXCEPTION 'unconfirmed/nonquantity effect must not post'; END IF;
 IF ph='output' OR (ph='register' AND NEW.payload->'intent'->>'operation' IN ('stock','holding')) THEN
 IF NOT EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=NEW.tenant_id AND id=(NEW.payload->>'holding')::uuid AND material_id=(NEW.payload->>'material')::uuid AND created_output=NEW.id) THEN RAISE EXCEPTION 'physical holding projection incomplete'; END IF;
 END IF;
 IF ph='register' AND NEW.payload->'intent'->>'operation'='container' THEN
 SELECT count(*) INTO n FROM api.container WHERE tenant_id=NEW.tenant_id AND created_output=NEW.id;
 IF n<>1+jsonb_array_length(NEW.payload->'wells') THEN RAISE EXCEPTION 'registered geometry incomplete'; END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER physical_projection_integrity AFTER INSERT ON api.task_execution_output DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.physical_projection_integrity();
CREATE FUNCTION api.container_chain(t text,c uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,api AS $$
 WITH RECURSIVE a(id,parent_id,location_id,pos,seq,output,depth,path) AS (
 SELECT id,parent_id,location_id,position,placement_seq,placement_output,0,ARRAY[id] FROM api.container WHERE tenant_id=t AND id=c
 UNION ALL SELECT p.id,p.parent_id,p.location_id,p.position,p.placement_seq,p.placement_output,a.depth+1,a.path||p.id FROM api.container p JOIN a ON p.id=a.parent_id WHERE p.tenant_id=t AND NOT p.id=ANY(a.path))
 SELECT jsonb_agg(jsonb_build_object('container',id,'parent',parent_id,'location',location_id,'position',pos,'seq',seq,'placement_output',output) ORDER BY depth) FROM a
$$;
CREATE FUNCTION api.current_inventory(holding uuid DEFAULT NULL) RETURNS TABLE(holding_id uuid,material_id uuid,material_spec text,container_id uuid,parent_container uuid,container_position text,location_id uuid,location_name text,site text,workcell text,recorded_quantity numeric,dimension text,closed boolean,identity jsonb,created_output uuid,placement_output uuid,placement_chain jsonb,pending_physical_scope boolean) LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
DECLARE t text:=api.guard(); BEGIN
 IF holding IS NOT NULL AND NOT EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=t AND id=holding) THEN RAISE EXCEPTION 'invalid tenant holding'; END IF;
 RETURN QUERY SELECT h.id,m.id,m.spec_id,c.id,c.parent_id,c.position,l.id,l.name,l.site,l.workcell,b.amount,h.dimension,h.closed,m.identity,m.created_output,c.placement_output,api.container_chain(t,c.id),EXISTS(SELECT 1 FROM api.task_execution_output_entity r WHERE r.tenant_id=t AND api.pending_output(t,r.output_id,r.member) AND ((r.role='resource' AND r.target_id=h.id) OR (r.role='container-resource' AND r.target_id IN(SELECT (link.value->>'container')::uuid FROM jsonb_array_elements(api.container_chain(t,c.id)) AS link(value))))) FROM api.container_content h JOIN api.material m ON (m.tenant_id,m.id)=(h.tenant_id,h.material_id) JOIN api.container c ON (c.tenant_id,c.id)=(h.tenant_id,h.container_id) JOIN api.material_balance b ON (b.tenant_id,b.holding_id)=(h.tenant_id,h.id) CROSS JOIN LATERAL api.place(t,c.id) l WHERE h.tenant_id=t AND (holding IS NULL OR h.id=holding);
END $$;
GRANT EXECUTE ON FUNCTION api.open_inventory_task(text,text,jsonb,text),api.inventory_accept(uuid,text,text,jsonb),api.current_inventory(uuid) TO tenant_a,tenant_b;
NOTIFY pgrst,'reload schema';
COMMIT;
