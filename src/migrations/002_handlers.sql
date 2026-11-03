\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
CREATE FUNCTION api.normalized(q numeric,u text,d text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE f numeric; r numeric;
BEGIN
 f:=CASE WHEN d='volume' THEN CASE u WHEN 'uL' THEN 1 WHEN 'mL' THEN 1000 END WHEN d='mass' THEN CASE u WHEN 'mg' THEN 1 WHEN 'g' THEN 1000 END WHEN d='count' AND u='each' THEN 1 END;
 IF f IS NULL OR q::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'unsupported unit/dimension'; END IF;
 r:=q*f; IF r<>round(r,6) OR (d='count' AND r<>trunc(r)) THEN RAISE EXCEPTION 'inexact quantity'; END IF; RETURN r;
END $$;
CREATE FUNCTION api.check_ledger() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,api AS $$
DECLARE t text:=NEW.tenant_id; m uuid;
BEGIN
 IF TG_TABLE_NAME='material_movement' THEN m:=NEW.id; ELSE m:=NEW.movement_id; END IF;
 IF EXISTS(SELECT 1 FROM api.material_posting p WHERE p.tenant_id=t AND p.movement_id=m AND p.delta<>api.normalized(p.entered,p.unit,p.dimension)) THEN RAISE EXCEPTION 'normalization mismatch'; END IF;
 IF (SELECT count(*)<2 OR coalesce(sum(delta),1)<>0 FROM api.material_posting WHERE tenant_id=t AND movement_id=m) THEN RAISE EXCEPTION 'unbalanced/incomplete movement'; END IF;
 IF EXISTS(SELECT 1 FROM api.material_balance b WHERE b.tenant_id=t AND (b.amount<0 OR b.amount<>(SELECT coalesce(sum(p.delta),0) FROM api.material_posting p WHERE p.tenant_id=t AND p.holding_id=b.holding_id))) THEN RAISE EXCEPTION 'balance projection mismatch'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER balanced AFTER INSERT ON api.material_movement DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.check_ledger();
CREATE CONSTRAINT TRIGGER balanced AFTER INSERT ON api.material_posting DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.check_ledger();
CREATE FUNCTION api.post(t text,m uuid,h uuid,a text,q numeric,u text,comp uuid DEFAULT NULL) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE v api.material_movement; d numeric;
BEGIN
 SELECT * INTO STRICT v FROM api.material_movement WHERE tenant_id=t AND id=m;
 d:=api.normalized(q,u,v.dimension);
 INSERT INTO api.material_posting(tenant_id,movement_id,material_id,dimension,holding_id,account,entered,unit,delta,compensated_id) VALUES(t,m,v.material_id,v.dimension,h,a,q,u,d,comp);
 IF h IS NOT NULL THEN
 IF NOT EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=t AND id=h AND NOT closed) THEN RAISE EXCEPTION 'closed holding'; END IF;
 UPDATE api.material_balance SET amount=amount+d,seq=seq+1 WHERE tenant_id=t AND holding_id=h;
 IF NOT FOUND THEN RAISE EXCEPTION 'missing balance'; END IF;
 END IF;
END $$;
CREATE FUNCTION api.edge(t text,o uuid,m text,r text,typ text,i uuid,s text DEFAULT '') RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE ok boolean;
BEGIN
 CASE typ
 WHEN 'material' THEN SELECT EXISTS(SELECT 1 FROM api.material WHERE tenant_id=t AND id=i) INTO ok;
 WHEN 'holding' THEN SELECT EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=t AND id=i) INTO ok;
 WHEN 'container' THEN SELECT EXISTS(SELECT 1 FROM api.container WHERE tenant_id=t AND id=i) INTO ok;
 WHEN 'task' THEN SELECT EXISTS(SELECT 1 FROM api.task WHERE tenant_id=t AND id=i) INTO ok;
 WHEN 'execution' THEN SELECT EXISTS(SELECT 1 FROM api.task_execution WHERE tenant_id=t AND id=i) INTO ok;
 WHEN 'output' THEN SELECT EXISTS(SELECT 1 FROM api.task_execution_output WHERE tenant_id=t AND id=i) INTO ok;
 WHEN 'observation' THEN SELECT EXISTS(SELECT 1 FROM api.observation WHERE tenant_id=t AND id=i) INTO ok;
 WHEN 'assessment' THEN SELECT EXISTS(SELECT 1 FROM api.assessment WHERE tenant_id=t AND id=i) INTO ok;
 ELSE RAISE EXCEPTION 'unsupported reference type'; END CASE;
 IF NOT coalesce(ok,false) THEN RAISE EXCEPTION 'invalid or cross-tenant reference'; END IF;
 INSERT INTO api.task_execution_output_entity VALUES(t,o,m,r,typ,i,s);
END $$;
CREATE FUNCTION api.place(t text,c uuid) RETURNS api.location LANGUAGE plpgsql STABLE SET search_path=pg_catalog,api AS $$
DECLARE v api.container; l api.location; seen uuid[]:='{}';
BEGIN
 LOOP
 IF c=ANY(seen) THEN RAISE EXCEPTION 'placement cycle'; END IF; seen:=seen||c;
 SELECT * INTO STRICT v FROM api.container WHERE tenant_id=t AND id=c;
 IF v.location_id IS NOT NULL THEN SELECT * INTO STRICT l FROM api.location WHERE tenant_id=t AND id=v.location_id; RETURN l; END IF;
 c:=v.parent_id;
 END LOOP;
END $$;
CREATE FUNCTION api.valid_assessment(t text,a uuid,seen uuid[] DEFAULT '{}') RETURNS boolean LANGUAGE plpgsql STABLE SET search_path=pg_catalog,api AS $$
DECLARE v api.assessment; d uuid;
BEGIN
 IF a=ANY(seen) THEN RETURN false; END IF;
 SELECT * INTO v FROM api.assessment WHERE tenant_id=t AND id=a; IF NOT FOUND THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=t AND role='invalidates' AND ((target_type='assessment' AND target_id=a) OR (target_type='observation' AND target_id=v.observation_id AND selector=v.observation_member))) THEN RETURN false; END IF;
 FOREACH d IN ARRAY v.dependencies LOOP IF NOT api.valid_assessment(t,d,seen||a) THEN RETURN false; END IF; END LOOP;
 RETURN true;
END $$;
CREATE FUNCTION api.usability(holding uuid,quantity numeric,intended_use text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
DECLARE t text:=api.guard(); h api.container_content; b numeric; policy jsonb; status text:='Yes'; reason text:='requirements satisfied'; basis jsonb:='[]'; a api.assessment;
BEGIN
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=holding;
 SELECT amount INTO STRICT b FROM api.material_balance WHERE tenant_id=t AND holding_id=holding;
 SELECT s.definition INTO policy FROM api.material m JOIN api.material_spec_catalog s ON (s.tenant_id,s.id)=(m.tenant_id,m.spec_id) WHERE m.tenant_id=t AND m.id=h.material_id;
 IF quantity IS NULL OR quantity<=0 OR quantity::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'invalid requested quantity'; END IF;
 IF h.closed OR b<quantity OR h.expires_at<=clock_timestamp() THEN status:='No'; reason:='closed, insufficient or expired';
 ELSIF intended_use<>'transfer' THEN status:='Unknown'; reason:='unsupported intended use';
 ELSIF EXISTS(SELECT 1 FROM api.task_execution_output_entity e JOIN api.task_execution_output o ON (o.tenant_id,o.id)=(e.tenant_id,e.output_id) WHERE e.tenant_id=t AND e.role='restriction' AND e.target_id=holding) THEN status:='No'; reason:='scoped restriction';
 ELSIF EXISTS(SELECT 1 FROM api.task_execution_output_entity r WHERE r.tenant_id=t AND r.role='resource' AND r.target_id=holding AND NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity st WHERE st.tenant_id=t AND st.role='settlement' AND st.selector=r.member AND st.output_id IN(SELECT z.id FROM api.task_execution_output z WHERE z.tenant_id=t AND z.port='settlement' AND z.payload->>'command'=r.output_id::text))) THEN status:='Unknown'; reason:='unresolved physical command';
 ELSIF coalesce((policy->>'storage_required')::boolean,false) THEN status:='Unknown'; reason:='historical environmental evidence evaluator not implemented';
 ELSIF policy ? 'qc_spec' THEN
 SELECT * INTO a FROM api.assessment WHERE tenant_id=t AND subject_type='holding' AND subject_id=holding AND spec_id=policy->>'qc_spec' ORDER BY id LIMIT 1;
 IF a.id IS NULL OR NOT api.valid_assessment(t,a.id) THEN status:='Unknown'; reason:='missing/stale required QC';
 ELSIF a.result->>'outcome'<>'pass' THEN status:='No'; reason:='QC failed'; END IF;
 IF a.id IS NOT NULL THEN basis:=jsonb_build_array(a.id); END IF;
 END IF;
 RETURN jsonb_build_object('status',status,'reasons',jsonb_build_array(reason),'basis',basis,'recorded_quantity',b,'usable_quantity',CASE WHEN status='Yes' THEN b ELSE 0 END);
END $$;
CREATE FUNCTION api.create_task(spec text,request_key text,intent jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); s api.task_spec_catalog; v api.task; x jsonb; k text; h api.container_content; loc api.location; ids text[]:='{}';
BEGIN
 SELECT * INTO STRICT s FROM api.task_spec_catalog WHERE tenant_id=t AND id=spec;
 SELECT * INTO v FROM api.task WHERE tenant_id=t AND task.request_key=create_task.request_key;
 IF FOUND THEN IF v.spec_id<>spec OR v.intent<>intent THEN RAISE EXCEPTION 'conflicting task retry'; END IF; RETURN v.id; END IF;
 IF s.handler<>'v1' OR jsonb_typeof(intent)<>'object' THEN RAISE EXCEPTION 'unsupported handler/payload'; END IF;
 IF s.definition->>'kind'='receipt' THEN
 IF NOT intent ?& ARRAY['supplier','delivery','line','lot','coa','holding','quantity','unit'] OR intent->>'supplier'='' OR intent->>'delivery'='' OR intent->>'line'='' THEN RAISE EXCEPTION 'receipt source/evidence required'; END IF;
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(intent->>'holding')::uuid AND NOT closed;
 PERFORM api.normalized((intent->>'quantity')::numeric,intent->>'unit',h.dimension);
 IF (intent->>'quantity')::numeric<=0 THEN RAISE EXCEPTION 'positive receipt required'; END IF;
 ELSIF s.definition->>'kind'='transfer' THEN
 IF coalesce(jsonb_array_length(intent->'items'),0) NOT BETWEEN 1 AND 384 THEN RAISE EXCEPTION 'work items required'; END IF;
 FOR x IN SELECT * FROM jsonb_array_elements(intent->'items') LOOP
 k:=x->>'key'; IF k IS NULL OR k=ANY(ids) THEN RAISE EXCEPTION 'duplicate/missing work key'; END IF; ids:=ids||k;
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(x->>'source')::uuid AND NOT closed;
 IF NOT EXISTS(SELECT 1 FROM api.container_content WHERE tenant_id=t AND id=(x->>'destination')::uuid AND material_id=h.material_id AND dimension=h.dimension AND NOT closed AND id<>h.id) THEN RAISE EXCEPTION 'incompatible/cross-tenant destination'; END IF;
 IF api.normalized((x->>'quantity')::numeric,x->>'unit',h.dimension)<=0 THEN RAISE EXCEPTION 'positive amount required'; END IF;
 END LOOP;
 ELSIF s.definition->>'kind'='acquisition' THEN
 IF coalesce(jsonb_array_length(intent->'mapping'),0)<>384 OR intent->>'plate' IS NULL THEN RAISE EXCEPTION '384 complete members required'; END IF;
 FOR x IN SELECT * FROM jsonb_array_elements(intent->'mapping') LOOP
 k:=x->>'member'; IF k IS NULL OR k=ANY(ids) THEN RAISE EXCEPTION 'duplicate member'; END IF; ids:=ids||k;
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(x->>'holding')::uuid;
 IF NOT EXISTS(SELECT 1 FROM api.container c WHERE c.tenant_id=t AND c.id=h.container_id AND c.id=(x->>'well')::uuid AND c.fixed AND c.parent_id=(intent->>'plate')::uuid AND c.position=x->>'member') THEN RAISE EXCEPTION 'wrong well mapping'; END IF;
 IF h.material_id<>(x->>'protein')::uuid OR NOT EXISTS(SELECT 1 FROM api.material WHERE tenant_id=t AND id=(x->>'target')::uuid) THEN RAISE EXCEPTION 'wrong protein/target'; END IF;
 IF NOT api.valid_assessment(t,(x->>'basis')::uuid) OR NOT EXISTS(SELECT 1 FROM api.assessment WHERE tenant_id=t AND id=(x->>'basis')::uuid AND subject_type='holding' AND subject_id=h.id AND result->>'outcome'='pass') THEN RAISE EXCEPTION 'required QC basis missing'; END IF;
 END LOOP;
 ELSIF s.definition->>'kind'='interpretation' THEN
 PERFORM 1 FROM api.observation WHERE tenant_id=t AND id=(intent->>'observation')::uuid; IF NOT FOUND THEN RAISE EXCEPTION 'invalid observation'; END IF;
 ELSIF s.definition->>'kind'='review' THEN
 IF NOT intent ?& ARRAY['observation','member','subject','subject_type'] THEN RAISE EXCEPTION 'frozen review subject and evidence required'; END IF;
 PERFORM 1 FROM api.observation WHERE tenant_id=t AND id=(intent->>'observation')::uuid;
 IF NOT FOUND THEN RAISE EXCEPTION 'invalid review evidence'; END IF;
 ELSIF s.definition->>'kind' NOT IN ('correction','composite') THEN RAISE EXCEPTION 'unsupported task kind'; END IF;
 -- Dependencies can only reference existing immutable tasks: this bounded admission rule excludes cycles.
 FOR x IN SELECT * FROM jsonb_array_elements(coalesce(intent->'dependencies','[]')) LOOP
 IF NOT EXISTS(SELECT 1 FROM api.task up JOIN api.task_spec_catalog us ON (us.tenant_id,us.id)=(up.tenant_id,up.spec_id) WHERE up.tenant_id=t AND up.id=(x->>'task')::uuid AND up.spec_id=x->>'spec' AND us.definition->'ports' ? (x->>'port')) OR x->>'port' NOT IN ('terminal','transition','interpretation','acquisition','coordination','review') OR x->>'mode' IS NULL OR x->>'mode' NOT IN ('historical','live') THEN RAISE EXCEPTION 'invalid prerequisite/port'; END IF;
 IF x ? 'output' OR x ? 'execution' THEN
 IF NOT EXISTS(SELECT 1 FROM api.task_execution_output oo JOIN api.task_execution ee ON (ee.tenant_id,ee.id)=(oo.tenant_id,oo.execution_id) WHERE oo.tenant_id=t AND oo.id=(x->>'output')::uuid AND ee.id=(x->>'execution')::uuid AND ee.task_id=(x->>'task')::uuid AND oo.port=x->>'port' AND oo.spec_id=x->>'spec') THEN RAISE EXCEPTION 'invalid/cross-tenant selected prerequisite'; END IF;
 END IF;
 END LOOP;
 INSERT INTO api.task(tenant_id,spec_id,request_key,intent,supplier,delivery,source_line) VALUES(t,spec,request_key,intent,CASE WHEN s.definition->>'kind'='receipt' THEN intent->>'supplier' END,CASE WHEN s.definition->>'kind'='receipt' THEN intent->>'delivery' END,CASE WHEN s.definition->>'kind'='receipt' THEN intent->>'line' END) RETURNING id INTO v.id;
 RETURN v.id;
END $$;
CREATE FUNCTION api.prerequisites(t text,intent jsonb) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE x jsonb; a api.assessment;
BEGIN
 FOR x IN SELECT * FROM jsonb_array_elements(coalesce(intent->'dependencies','[]')) LOOP
 IF NOT EXISTS(SELECT 1 FROM api.task_execution_output oo JOIN api.task_execution ee ON (ee.tenant_id,ee.id)=(oo.tenant_id,oo.execution_id) WHERE oo.tenant_id=t AND oo.id=(x->>'output')::uuid AND ee.id=(x->>'execution')::uuid AND ee.task_id=(x->>'task')::uuid AND oo.port=x->>'port' AND oo.spec_id=x->>'spec' AND (oo.port<>'terminal' OR oo.payload->>'state'='Completed')) THEN RAISE EXCEPTION 'missing exact prerequisite selection'; END IF;
 IF x->>'mode'='live' THEN
 SELECT * INTO STRICT a FROM api.assessment WHERE tenant_id=t AND output_id=(x->>'output')::uuid AND member=x->>'member';
 IF NOT api.valid_assessment(t,a.id) OR a.result->>'outcome' NOT IN ('pass','binding') THEN RAISE EXCEPTION 'stale prerequisite approval'; END IF;
 END IF;
 END LOOP;
END $$;
CREATE FUNCTION api.start_execution(task uuid,workcell text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); v api.task; i uuid; x jsonb; s jsonb; a api.assessment;
BEGIN
 SELECT * INTO STRICT v FROM api.task WHERE tenant_id=t AND id=task;
 IF v.state<>'Pending' THEN RAISE EXCEPTION 'task not pending'; END IF;
 IF NOT EXISTS(SELECT 1 FROM api.location WHERE tenant_id=t AND location.workcell=start_execution.workcell) THEN RAISE EXCEPTION 'workcell not authorized'; END IF;
 SELECT definition INTO s FROM api.task_spec_catalog WHERE tenant_id=t AND id=v.spec_id;
 IF s->>'kind'<>'composite' THEN PERFORM api.prerequisites(t,v.intent); END IF;
 INSERT INTO api.task_execution(tenant_id,task_id,spec_id,attempt,workcell) SELECT t,v.id,v.spec_id,coalesce(max(attempt),0)+1,workcell FROM api.task_execution WHERE tenant_id=t AND task_id=task RETURNING id INTO i;
 RETURN i;
END $$;
CREATE UNIQUE INDEX unique_command_identity ON api.task_execution_output(tenant_id,(payload->>'command_id')) WHERE port='command';
CREATE UNIQUE INDEX unique_terminal ON api.task_execution_output(tenant_id,execution_id) WHERE port='terminal';
CREATE FUNCTION api.accept(execution uuid,request_key text,port text,payload jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); e api.task_execution; taskrow api.task; spec api.task_spec_catalog; old api.task_execution_output;
 o uuid:=gen_random_uuid(); p jsonb:=payload; req jsonb:=jsonb_build_object('port',port,'payload',payload); kind text;
 x jsonb; y jsonb; h api.container_content; dest api.container_content; l api.location; dl api.location;
 q numeric; u text; m uuid; rev uuid; orig api.material_movement; posting api.material_posting; obs api.observation; a api.assessment; aid uuid; dep uuid; oid uuid; ids text[]:='{}'; k text; cmd api.task_execution_output; hist jsonb; def jsonb;
BEGIN
 SELECT * INTO STRICT e FROM api.task_execution WHERE tenant_id=t AND id=execution;
 SELECT * INTO STRICT taskrow FROM api.task WHERE tenant_id=t AND id=e.task_id;
 SELECT * INTO STRICT spec FROM api.task_spec_catalog WHERE tenant_id=t AND id=e.spec_id;
 kind:=spec.definition->>'kind';
 SELECT * INTO old FROM api.task_execution_output WHERE tenant_id=t AND execution_id=execution AND task_execution_output.request_key=accept.request_key;
 IF FOUND THEN IF old.request<>req THEN RAISE EXCEPTION 'conflicting acceptance retry'; END IF; RETURN old.id; END IF;
 IF NOT (spec.definition->'ports' ? port) OR spec.handler<>'v1' OR jsonb_typeof(payload)<>'object' THEN RAISE EXCEPTION 'unsupported port/handler/payload'; END IF;
 IF e.state<>'Running' AND NOT (port='settlement' AND spec.definition->>'recovery'='settlement') THEN RAISE EXCEPTION 'terminal execution'; END IF;
 IF port='terminal' THEN
 IF payload->>'state' NOT IN ('Completed','Failed','Canceled') OR payload->>'reason' IS NULL THEN RAISE EXCEPTION 'terminal disposition/reason required'; END IF;
 IF payload->>'state'='Completed' THEN
 FOR x IN SELECT * FROM jsonb_array_elements(coalesce(spec.definition->'required_ports','[]')) LOOP
 IF NOT EXISTS(SELECT 1 FROM api.task_execution_output WHERE tenant_id=t AND execution_id=execution AND task_execution_output.port=x#>>'{}') THEN RAISE EXCEPTION 'mandatory execution condition missing: %',x; END IF;
 END LOOP;
 IF kind='transfer' AND EXISTS(SELECT 1 FROM jsonb_array_elements(taskrow.intent->'items') i WHERE NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=t AND target_id=taskrow.id AND role='settlement' AND selector=i->>'key')) THEN RAISE EXCEPTION 'unresolved mandatory work'; END IF;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'order',accepted_order,'port',task_execution_output.port) ORDER BY accepted_order),'[]') INTO hist FROM api.task_execution_output WHERE tenant_id=t AND execution_id=execution;
 p:=payload||jsonb_build_object('unresolved',coalesce((SELECT jsonb_agg(i->>'key') FROM jsonb_array_elements(coalesce(taskrow.intent->'items','[]')) i WHERE NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=t AND target_id=taskrow.id AND role='settlement' AND selector=i->>'key')),'[]'),'history',hist,'boundary',coalesce((SELECT max(accepted_order) FROM api.task_execution_output WHERE tenant_id=t),0),'task',taskrow.id,'spec',e.spec_id);
 END IF;
 INSERT INTO api.task_execution_output(tenant_id,id,execution_id,spec_id,request_key,port,request,payload,actor) VALUES(t,o,execution,e.spec_id,request_key,port,req,p,current_setting('role'));
 IF port='receipt' THEN
 IF payload IS DISTINCT FROM jsonb_build_object('confirmed',true,'evidence',payload->>'evidence') OR coalesce(payload->>'evidence','')='' THEN RAISE EXCEPTION 'explicit receipt confirmation/evidence required'; END IF;
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(taskrow.intent->>'holding')::uuid;
 l:=api.place(t,h.container_id); IF l.workcell IS DISTINCT FROM e.workcell THEN RAISE EXCEPTION 'wrong workcell'; END IF;
 PERFORM api.edge(t,o,'receipt','settlement','task',taskrow.id,'receipt');
 INSERT INTO api.material_movement(tenant_id,output_id,member,material_id,dimension,kind) VALUES(t,o,'receipt',h.material_id,h.dimension,'receipt') RETURNING id INTO m;
 q:=(taskrow.intent->>'quantity')::numeric; u:=taskrow.intent->>'unit';
 PERFORM api.post(t,m,NULL,'receipt',-q,u); PERFORM api.post(t,m,h.id,NULL,q,u);
 ELSIF port='command' THEN
 PERFORM api.prerequisites(t,taskrow.intent);
 IF kind<>'transfer' OR coalesce(payload->>'command_id','')='' OR payload->>'protocol'<>'external-fence-v1' THEN RAISE EXCEPTION 'command fencing identity required'; END IF;
 -- All items are reserved together. The external actuator must deduplicate this identity; this RPC never dispatches.
 FOR x IN SELECT jsonb_build_object('source',i->>'source','quantity',sum(api.normalized((i->>'quantity')::numeric,i->>'unit',cc.dimension))) FROM jsonb_array_elements(taskrow.intent->'items') i JOIN api.container_content cc ON cc.tenant_id=t AND cc.id=(i->>'source')::uuid GROUP BY i->>'source' LOOP
 IF api.usability((x->>'source')::uuid,(x->>'quantity')::numeric,'transfer')->>'status'<>'Yes' THEN RAISE EXCEPTION 'aggregate source not usable'; END IF;
 END LOOP;
 FOR x IN SELECT * FROM jsonb_array_elements(taskrow.intent->'items') LOOP
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(x->>'source')::uuid;
 SELECT * INTO STRICT dest FROM api.container_content WHERE tenant_id=t AND id=(x->>'destination')::uuid;
 l:=api.place(t,h.container_id); dl:=api.place(t,dest.container_id);
 IF l.site<>dl.site OR l.workcell IS DISTINCT FROM e.workcell OR dl.workcell IS DISTINCT FROM e.workcell THEN RAISE EXCEPTION 'site/workcell violation'; END IF;
 IF EXISTS(SELECT 1 FROM api.task_execution_output_entity r WHERE r.tenant_id=t AND r.output_id<>o AND r.role='resource' AND r.target_id IN(h.id,dest.id) AND NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity st WHERE st.tenant_id=t AND st.output_id IN(SELECT z.id FROM api.task_execution_output z WHERE z.tenant_id=t AND z.port='settlement' AND z.payload->>'command'=r.output_id::text) AND st.role='settlement' AND st.selector=r.member)) THEN RAISE EXCEPTION 'unresolved command scope'; END IF;
  PERFORM api.edge(t,o,x->>'key','command','task',taskrow.id,x->>'key');
 PERFORM api.edge(t,o,x->>'key','resource','holding',h.id); PERFORM api.edge(t,o,x->>'key','resource','holding',dest.id);
 END LOOP;
 ELSIF port='settlement' THEN
 SELECT * INTO STRICT cmd FROM api.task_execution_output WHERE tenant_id=t AND id=(payload->>'command')::uuid AND execution_id=execution AND task_execution_output.port='command';
 IF coalesce(payload->>'evidence','')='' THEN RAISE EXCEPTION 'physical evidence required'; END IF;
 SELECT i INTO STRICT x FROM jsonb_array_elements(taskrow.intent->'items') i WHERE i->>'key'=payload->>'key';
 IF payload->>'outcome' IS NULL OR payload->>'outcome' NOT IN ('full','partial','zero','unknown') THEN RAISE EXCEPTION 'outcome required'; END IF;
 PERFORM api.edge(t,o,x->>'key','command-basis','output',cmd.id);
 IF payload->>'outcome'<>'unknown' THEN
 IF payload->>'fence_retired' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'positive external command retirement/fencing required'; END IF;
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(x->>'source')::uuid;
 SELECT * INTO STRICT dest FROM api.container_content WHERE tenant_id=t AND id=(x->>'destination')::uuid;
 q:=(payload->>'quantity')::numeric; u:=x->>'unit';
 IF q IS NULL OR api.normalized(q,u,h.dimension)<0 OR q>(x->>'quantity')::numeric OR (payload->>'outcome'='zero' AND q<>0) OR (payload->>'outcome'='full' AND q<>(x->>'quantity')::numeric) OR (payload->>'outcome'='partial' AND (q<=0 OR q>=(x->>'quantity')::numeric)) THEN RAISE EXCEPTION 'invalid confirmed amount'; END IF;
 PERFORM api.edge(t,o,x->>'key','settlement','task',taskrow.id,x->>'key');
 IF q>0 THEN
 INSERT INTO api.material_movement(tenant_id,output_id,member,material_id,dimension,kind) VALUES(t,o,x->>'key',h.material_id,h.dimension,'transfer') RETURNING id INTO m;
 PERFORM api.post(t,m,h.id,NULL,-q,u); PERFORM api.post(t,m,dest.id,NULL,q,u);
 END IF;
 END IF;
 ELSIF port='terminal' THEN
 UPDATE api.task_execution SET state=payload->>'state',terminal_output=o WHERE tenant_id=t AND id=execution AND state='Running';
 IF NOT FOUND THEN RAISE EXCEPTION 'terminal predecessor conflict'; END IF;
 ELSIF port='checkpoint' THEN
 IF payload->>'name' IS DISTINCT FROM 'verified' OR payload->>'evidence' IS NULL THEN RAISE EXCEPTION 'unsupported checkpoint'; END IF;
 ELSIF port='acquisition' THEN
 IF payload->'mapping' IS DISTINCT FROM taskrow.intent->'mapping' THEN RAISE EXCEPTION 'incomplete/incorrect acquisition mapping'; END IF;
 x:=payload->'artifact';
 IF NOT x ?& ARRAY['bucket','key','version','sha256','format','size'] OR x->>'version'='' OR x->>'format'<>'binding-curves@1' OR x->>'sha256' !~ '^[0-9a-f]{64}$' OR (x->>'size')::bigint<=0 THEN RAISE EXCEPTION 'immutable artifact descriptor required'; END IF;
 INSERT INTO api.observation(tenant_id,output_id,spec_id,artifact,mapping) VALUES(t,o,spec.definition->>'observation_spec',x,payload->'mapping') RETURNING id INTO oid;
 FOR x IN SELECT * FROM jsonb_array_elements(payload->'mapping') LOOP
 IF NOT api.valid_assessment(t,(x->>'basis')::uuid) THEN RAISE EXCEPTION 'stale acquisition basis'; END IF;
 PERFORM api.edge(t,o,x->>'member','protein','material',(x->>'protein')::uuid);
 PERFORM api.edge(t,o,x->>'member','target','material',(x->>'target')::uuid);
 PERFORM api.edge(t,o,x->>'member','sample','holding',(x->>'holding')::uuid);
 PERFORM api.edge(t,o,x->>'member','well','container',(x->>'well')::uuid);
 PERFORM api.edge(t,o,x->>'member','scientific-dependency','assessment',(x->>'basis')::uuid);
 END LOOP;
 ELSIF port='interpretation' THEN
 SELECT * INTO STRICT obs FROM api.observation WHERE tenant_id=t AND id=(taskrow.intent->>'observation')::uuid;
 SELECT definition INTO STRICT def FROM api.assessment_specification_catalog WHERE tenant_id=t AND id=spec.definition->>'assessment_spec';
 IF obs.spec_id<>def->>'observation_spec' OR coalesce(jsonb_array_length(payload->'results'),-1)<>jsonb_array_length(obs.mapping) THEN RAISE EXCEPTION 'incompatible version/incomplete conclusions'; END IF;
 FOR x IN SELECT * FROM jsonb_array_elements(payload->'results') LOOP
 k:=x->>'member'; IF k=ANY(ids) OR k IS NULL THEN RAISE EXCEPTION 'duplicate conclusion'; END IF; ids:=ids||k;
 SELECT j INTO STRICT y FROM jsonb_array_elements(obs.mapping) j WHERE j->>'member'=k;
 IF x->'subject' IS DISTINCT FROM (y-'basis') OR x->>'outcome' IS NULL OR x->>'outcome' NOT IN ('binding','nonbinding','inconclusive') OR x->'dependencies' IS DISTINCT FROM jsonb_build_array(y->>'basis') THEN RAISE EXCEPTION 'pairing/required dependency mismatch'; END IF;
 dep:=(y->>'basis')::uuid; IF NOT api.valid_assessment(t,dep) THEN RAISE EXCEPTION 'stale scientific basis'; END IF;
 INSERT INTO api.assessment(tenant_id,output_id,member,spec_id,subject_type,subject_id,subject,result,observation_id,observation_member,dependencies) VALUES(t,o,k,spec.definition->>'assessment_spec','pair',(y->>'protein')::uuid,x->'subject',x-'subject'-'dependencies',obs.id,k,ARRAY[dep]) RETURNING id INTO aid;
 PERFORM api.edge(t,o,k,'evidence','observation',obs.id,k); PERFORM api.edge(t,o,k,'scientific-dependency','assessment',dep);
 PERFORM api.edge(t,o,k,'subject-protein','material',(y->>'protein')::uuid); PERFORM api.edge(t,o,k,'subject-target','material',(y->>'target')::uuid);
 END LOOP;
 ELSIF port='review' THEN
 -- A bounded operational QC review over an exact dataset member; not a general scientific evaluator.
 IF payload-'outcome' IS DISTINCT FROM taskrow.intent THEN RAISE EXCEPTION 'review must match frozen scope/basis'; END IF;
 SELECT * INTO STRICT obs FROM api.observation WHERE tenant_id=t AND id=(payload->>'observation')::uuid;
 SELECT definition INTO STRICT def FROM api.assessment_specification_catalog WHERE tenant_id=t AND id=spec.definition->>'assessment_spec';
 IF obs.spec_id IS DISTINCT FROM def->>'observation_spec' OR EXISTS(SELECT 1 FROM api.task_execution_output_entity WHERE tenant_id=t AND role='invalidates' AND target_type='observation' AND target_id=obs.id AND selector=payload->>'member') THEN RAISE EXCEPTION 'incompatible/stale review evidence'; END IF;
 IF payload->>'subject_type'='task' AND NOT EXISTS(SELECT 1 FROM api.task_execution_output oo JOIN api.task_execution ee ON (ee.tenant_id,ee.id)=(oo.tenant_id,oo.execution_id) WHERE oo.tenant_id=t AND oo.id=obs.output_id AND ee.task_id=(payload->>'subject')::uuid) THEN RAISE EXCEPTION 'evidence does not assess selected task'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(obs.mapping) j WHERE j->>'member'=payload->>'member') OR payload->>'outcome' NOT IN ('pass','fail') THEN RAISE EXCEPTION 'invalid review basis/result'; END IF;
 IF payload->>'subject_type'='task' THEN PERFORM 1 FROM api.task WHERE tenant_id=t AND id=(payload->>'subject')::uuid;
 ELSIF payload->>'subject_type'='holding' THEN PERFORM 1 FROM api.container_content WHERE tenant_id=t AND id=(payload->>'subject')::uuid;
 ELSE RAISE EXCEPTION 'unsupported subject'; END IF;
 IF NOT FOUND THEN RAISE EXCEPTION 'invalid review subject'; END IF;
 INSERT INTO api.assessment(tenant_id,output_id,member,spec_id,subject_type,subject_id,subject,result,observation_id,observation_member) VALUES(t,o,payload->>'member',spec.definition->>'assessment_spec',payload->>'subject_type',(payload->>'subject')::uuid,payload-'outcome',jsonb_build_object('outcome',payload->>'outcome'),obs.id,payload->>'member') RETURNING id INTO aid;
 PERFORM api.edge(t,o,payload->>'member','evidence','observation',obs.id,payload->>'member');
 PERFORM api.edge(t,o,payload->>'member','subject',CASE payload->>'subject_type' WHEN 'task' THEN 'task' ELSE 'holding' END,(payload->>'subject')::uuid);
 ELSIF port='transition' THEN
 SELECT * INTO STRICT a FROM api.assessment WHERE tenant_id=t AND id=(payload->>'assessment')::uuid;
 SELECT * INTO STRICT taskrow FROM api.task WHERE tenant_id=t AND id=(payload->>'target')::uuid;
 SELECT definition INTO STRICT def FROM api.task_spec_catalog WHERE tenant_id=t AND id=taskrow.spec_id;
 IF a.subject_type<>'task' OR a.subject_id<>taskrow.id OR a.spec_id IS DISTINCT FROM def->>'completion_assessment' OR a.result->>'outcome'<>'pass' OR NOT api.valid_assessment(t,a.id) OR taskrow.state<>'Pending' OR taskrow.seq<>(payload->>'expected_seq')::bigint OR payload->>'expected_seq' IS NULL THEN RAISE EXCEPTION 'unauthorized/stale transition or predecessor'; END IF;
 IF taskrow.id<>e.task_id AND (NOT coalesce((spec.definition->>'cross_task')::boolean,false) OR NOT coalesce((def->>'cross_task')::boolean,false)) THEN RAISE EXCEPTION 'cross-task control forbidden'; END IF;
 PERFORM api.edge(t,o,'transition','target-task','task',taskrow.id); PERFORM api.edge(t,o,'transition','authority','assessment',a.id);
 UPDATE api.task SET state='Completed',seq=seq+1,last_output=o WHERE tenant_id=t AND id=taskrow.id;
 ELSIF port='coordination' THEN
 IF coalesce(jsonb_array_length(payload->'selections'),-1)<>coalesce(jsonb_array_length(taskrow.intent->'dependencies'),0) THEN RAISE EXCEPTION 'complete explicit selections required'; END IF;
 FOR x IN SELECT * FROM jsonb_array_elements(taskrow.intent->'dependencies') LOOP
 SELECT j INTO STRICT y FROM jsonb_array_elements(payload->'selections') j WHERE j->>'role'=x->>'role';
 SELECT z.* INTO STRICT old FROM api.task_execution_output z JOIN api.task_execution ex ON (ex.tenant_id,ex.id)=(z.tenant_id,z.execution_id) WHERE z.tenant_id=t AND z.id=(y->>'output')::uuid AND ex.task_id=(x->>'task')::uuid AND ex.id=(y->>'execution')::uuid AND z.port=x->>'port' AND z.spec_id=x->>'spec';
 IF old.port='terminal' AND old.payload->>'state'<>'Completed' THEN RAISE EXCEPTION 'unsuccessful prerequisite'; END IF;
 IF x->>'mode'='live' THEN
 SELECT * INTO STRICT a FROM api.assessment WHERE tenant_id=t AND output_id=old.id AND member=y->>'member';
 IF NOT api.valid_assessment(t,a.id) OR a.result->>'outcome' NOT IN ('pass','binding') THEN RAISE EXCEPTION 'invalid live approval'; END IF;
 PERFORM api.edge(t,o,x->>'role','selected-assessment','assessment',a.id);
 END IF;
 PERFORM api.edge(t,o,x->>'role','selected-output','output',old.id,coalesce(y->>'member',''));
 PERFORM api.edge(t,o,x->>'role','selected-execution','execution',old.execution_id);
 PERFORM api.edge(t,o,x->>'role','child-task','task',(x->>'task')::uuid);
 END LOOP;
 ELSIF port='correction' THEN
 IF payload->>'type'='replace' THEN
 IF coalesce(payload->>'reason','')='' THEN RAISE EXCEPTION 'correction evidence required'; END IF;
 SELECT * INTO STRICT orig FROM api.material_movement WHERE tenant_id=t AND id=(payload->>'original')::uuid AND material_movement.kind IN ('receipt','transfer');
 IF (SELECT count(*) FROM api.material_posting WHERE tenant_id=t AND movement_id=orig.id)<>2 THEN RAISE EXCEPTION 'unsupported correction shape'; END IF;
 IF EXISTS(SELECT 1 FROM api.task_execution_output_entity r WHERE r.tenant_id=t AND r.role='resource' AND r.target_id IN(SELECT holding_id FROM api.material_posting WHERE tenant_id=t AND movement_id=orig.id) AND NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity st WHERE st.tenant_id=t AND st.role='settlement' AND st.selector=r.member AND st.output_id IN(SELECT z.id FROM api.task_execution_output z WHERE z.tenant_id=t AND z.port='settlement' AND z.payload->>'command'=r.output_id::text))) THEN RAISE EXCEPTION 'pending physical scope prevents historical quantity replacement'; END IF;
 q:=(payload->>'quantity')::numeric;
 IF q IS NULL OR q<=0 THEN RAISE EXCEPTION 'replacement positive quantity required'; END IF;
 INSERT INTO api.material_movement(tenant_id,output_id,member,material_id,dimension,kind,original_id) VALUES(t,o,'reversal',orig.material_id,orig.dimension,'reversal',orig.id) RETURNING id INTO rev;
 INSERT INTO api.material_movement(tenant_id,output_id,member,material_id,dimension,kind,original_id) VALUES(t,o,'replacement',orig.material_id,orig.dimension,'replacement',orig.id) RETURNING id INTO m;
 FOR posting IN SELECT * FROM api.material_posting WHERE tenant_id=t AND movement_id=orig.id LOOP
 PERFORM api.post(t,rev,posting.holding_id,posting.account,-posting.entered,posting.unit,posting.id);
 PERFORM api.post(t,m,posting.holding_id,posting.account,sign(posting.delta)*q,payload->>'unit');
 END LOOP;
 PERFORM api.edge(t,o,'correction','original-claim','output',orig.output_id);
 ELSIF payload->>'type'='reconcile' THEN
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(payload->>'holding')::uuid;
 IF payload->>'custody' IS DISTINCT FROM 'confirmed' OR coalesce(payload->>'count_id','')='' OR coalesce(payload->>'evidence','')='' OR payload->>'observed' IS NULL OR (payload->>'observed')::numeric<0 THEN RAISE EXCEPTION 'independent count/custody evidence required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM api.material_balance WHERE tenant_id=t AND holding_id=h.id AND seq=(payload->>'expected_seq')::bigint) THEN RAISE EXCEPTION 'stale count sequence'; END IF;
 IF EXISTS(SELECT 1 FROM api.task_execution_output_entity r WHERE r.tenant_id=t AND r.role='resource' AND r.target_id=h.id AND NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity st WHERE st.tenant_id=t AND st.role='settlement' AND st.selector=r.member AND st.output_id IN(SELECT z.id FROM api.task_execution_output z WHERE z.tenant_id=t AND z.port='settlement' AND z.payload->>'command'=r.output_id::text))) THEN RAISE EXCEPTION 'unresolved command prevents reconciliation'; END IF;
 PERFORM api.edge(t,o,'count','count-use','holding',h.id,payload->>'count_id');
 SELECT (payload->>'observed')::numeric-amount INTO q FROM api.material_balance WHERE tenant_id=t AND holding_id=h.id;
 IF q<>0 THEN
 INSERT INTO api.material_movement(tenant_id,output_id,member,material_id,dimension,kind) VALUES(t,o,'discrepancy',h.material_id,h.dimension,'discrepancy') RETURNING id INTO m;
 u:=CASE h.dimension WHEN 'volume' THEN 'uL' WHEN 'mass' THEN 'mg' ELSE 'each' END;
 PERFORM api.post(t,m,h.id,NULL,q,u); PERFORM api.post(t,m,NULL,'discrepancy',-q,u);
 END IF;
 ELSIF payload->>'type'='scientific' THEN
 IF coalesce(payload->>'reason','')='' THEN RAISE EXCEPTION 'correction reason required'; END IF;
 IF payload->>'target_type'='observation' THEN
 SELECT * INTO STRICT obs FROM api.observation WHERE tenant_id=t AND id=(payload->>'target')::uuid;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(obs.mapping) j WHERE j->>'member'=payload->>'member') THEN RAISE EXCEPTION 'unknown corrected member'; END IF;
 END IF;
 IF payload->>'target_type' NOT IN ('observation','assessment') THEN RAISE EXCEPTION 'unsupported scientific correction'; END IF;
 PERFORM api.edge(t,o,'correction','invalidates',payload->>'target_type',(payload->>'target')::uuid,coalesce(payload->>'member',''));
 ELSIF payload->>'type'='close_holding' THEN
 SELECT * INTO STRICT h FROM api.container_content WHERE tenant_id=t AND id=(payload->>'holding')::uuid AND NOT closed;
 IF NOT EXISTS(SELECT 1 FROM api.material_balance WHERE tenant_id=t AND holding_id=h.id AND amount=0) THEN RAISE EXCEPTION 'closure requires zero quantity'; END IF;
 IF EXISTS(SELECT 1 FROM api.task_execution_output_entity r WHERE r.tenant_id=t AND r.role='resource' AND r.target_id=h.id AND NOT EXISTS(SELECT 1 FROM api.task_execution_output_entity st WHERE st.tenant_id=t AND st.role='settlement' AND st.selector=r.member AND st.output_id IN(SELECT z.id FROM api.task_execution_output z WHERE z.tenant_id=t AND z.port='settlement' AND z.payload->>'command'=r.output_id::text))) THEN RAISE EXCEPTION 'closure requires resolved physical scope'; END IF;
 PERFORM api.edge(t,o,'closure','closed-holding','holding',h.id);
 UPDATE api.container_content SET closed=true,close_output=o WHERE tenant_id=t AND id=h.id;
 ELSIF payload->>'type'='restrict' THEN
 PERFORM api.edge(t,o,'restriction','restriction','holding',(payload->>'holding')::uuid);
 ELSE RAISE EXCEPTION 'unsupported correction'; END IF;
 ELSE RAISE EXCEPTION 'unsupported handler'; END IF;
 RETURN o;
END $$;
GRANT EXECUTE ON FUNCTION api.create_task(text,text,jsonb),api.start_execution(uuid,text),api.accept(uuid,text,text,jsonb),api.usability(uuid,numeric,text) TO tenant_a,tenant_b;
COMMIT;
