\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
SELECT pg_advisory_xact_lock(741903);

-- Finite shape checks: missing keys, SQL NULL, JSON null and coercible nonstrings
-- are not evidence. Called after recognized retries, before new acceptance.
CREATE FUNCTION api.require_fields(j jsonb, strings text[] DEFAULT '{}', numbers text[] DEFAULT '{}') RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE k text;
BEGIN
 IF jsonb_typeof(j) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'object required'; END IF;
 FOREACH k IN ARRAY strings LOOP
  IF jsonb_typeof(j->k) IS DISTINCT FROM 'string' OR coalesce(btrim(j->>k),'')='' THEN RAISE EXCEPTION 'nonempty string required: %',k; END IF;
 END LOOP;
 FOREACH k IN ARRAY numbers LOOP
  IF jsonb_typeof(j->k) IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'number required: %',k; END IF;
 END LOOP;
END $$;

-- Patch retained functions rather than rewriting historical migrations. Exact
-- anchors fail the migration if the expected implementation has changed.
DO $$ DECLARE sig text; b text; pair text[]; patches text[][]; BEGIN
 FOREACH sig IN ARRAY ARRAY['api.create_task(text,text,jsonb)','api.accept(uuid,text,text,jsonb)','api.prerequisites(text,jsonb)','api.register_receipt(text,jsonb,text,text)','api.normalized(numeric,text,text)','api.open_inventory_task(text,text,jsonb,text)','api.usability(uuid,numeric,text)','api.inventory_accept(uuid,text,text,jsonb)' ] LOOP
 b:=pg_get_functiondef(sig::regprocedure);
 patches:=CASE sig
 WHEN 'api.create_task(text,text,jsonb)' THEN ARRAY[
  ARRAY['IF v.spec_id<>spec OR v.intent<>intent','IF v.spec_id IS DISTINCT FROM spec OR v.intent IS DISTINCT FROM intent'],
  ARRAY['IF s.handler<>''v1'' OR jsonb_typeof(intent)<>''object''','IF s.handler<>''v1'' OR jsonb_typeof(intent) IS DISTINCT FROM ''object'''],
  ARRAY['IF s.definition->>''kind''=''receipt'' THEN','IF s.definition->>''kind''=''receipt'' THEN
 PERFORM api.require_fields(intent,ARRAY[''supplier'',''delivery'',''line'',''lot'',''holding'',''unit''],ARRAY[''quantity'']);'],
  ARRAY['k:=x->>''key'';','PERFORM api.require_fields(x,ARRAY[''key'',''source'',''destination'',''unit''],ARRAY[''quantity'']); k:=x->>''key'';']]
 WHEN 'api.accept(uuid,text,text,jsonb)' THEN ARRAY[
  ARRAY['IF NOT (spec.definition->''ports'' ? port) OR spec.handler<>''v1'' OR jsonb_typeof(payload)<>''object''','IF port IS NULL OR NOT (spec.definition->''ports'' ? port) OR spec.handler<>''v1'' OR jsonb_typeof(payload) IS DISTINCT FROM ''object'''],
  ARRAY['payload->>''protocol''<>''external-fence-v1''','payload->>''protocol'' IS DISTINCT FROM ''external-fence-v1'''],
  ARRAY['a.result->>''outcome''<>''pass''','a.result->>''outcome'' IS DISTINCT FROM ''pass'''],
  ARRAY['payload->>''outcome'' NOT IN (''pass'',''fail'')','(payload->>''outcome'' IN (''pass'',''fail'')) IS NOT TRUE'],
  ARRAY['ELSIF port=''review'' THEN','ELSIF port=''review'' THEN
 PERFORM api.require_fields(payload,ARRAY[''observation'',''member'',''subject'',''subject_type'',''outcome'']);'],
  ARRAY['IF port=''terminal'' THEN','IF port=''terminal'' THEN
 PERFORM api.require_fields(payload,ARRAY[''state'',''reason'']);'],
  ARRAY['ELSIF port=''settlement'' THEN','ELSIF port=''settlement'' THEN
 PERFORM api.require_fields(payload,ARRAY[''command'',''key'',''outcome'',''evidence'']);
 IF payload ? ''fence_retired'' AND jsonb_typeof(payload->''fence_retired'') IS DISTINCT FROM ''boolean'' THEN RAISE EXCEPTION ''boolean retirement required''; END IF;'],
  ARRAY['ELSIF port=''checkpoint'' THEN','ELSIF port=''checkpoint'' THEN
 PERFORM api.require_fields(payload,ARRAY[''name'',''evidence'']);'],
  ARRAY['ELSIF port=''command'' THEN','ELSIF port=''command'' THEN
 PERFORM api.require_fields(payload,ARRAY[''command_id'',''protocol'']);'],
  ARRAY['x:=payload->''artifact'';','x:=payload->''artifact'';
 PERFORM api.require_fields(x,ARRAY[''bucket'',''key'',''version'',''sha256'',''format''],ARRAY[''size'']);'],
  ARRAY['a.result->>''outcome'' NOT IN (''pass'',''binding'')','(a.result->>''outcome'' IN (''pass'',''binding'')) IS NOT TRUE']]
 WHEN 'api.prerequisites(text,jsonb)' THEN ARRAY[
  ARRAY['a.result->>''outcome'' NOT IN (''pass'',''binding'')','(a.result->>''outcome'' IN (''pass'',''binding'')) IS NOT TRUE']]
 WHEN 'api.register_receipt(text,jsonb,text,text)' THEN ARRAY[
  ARRAY['BEGIN
 SELECT * INTO v','BEGIN
 PERFORM api.require_fields(intent,ARRAY[''supplier'',''delivery'',''line'']);
 SELECT * INTO v']]
 WHEN 'api.open_inventory_task(text,text,jsonb,text)' THEN ARRAY[
  ARRAY['v.spec_id<>spec OR v.intent<>frozen OR e.workcell<>workcell','v.spec_id IS DISTINCT FROM spec OR v.intent IS DISTINCT FROM frozen OR e.workcell IS DISTINCT FROM workcell']]
 WHEN 'api.usability(uuid,numeric,text)' THEN ARRAY[
  ARRAY['a.result->>''outcome''<>''pass''','a.result->>''outcome'' IS DISTINCT FROM ''pass''']]
 WHEN 'api.normalized(numeric,text,text)' THEN ARRAY[
  ARRAY['IF f IS NULL OR q::text','IF q IS NULL OR f IS NULL OR q::text']]
 ELSE ARRAY[
  ARRAY['i:=v.intent;','PERFORM api.require_fields(payload,ARRAY[''evidence'']);
 IF phase=''command'' THEN PERFORM api.require_fields(payload,ARRAY[''command_id'',''protocol'']); END IF;
 IF payload ? ''confirmed'' AND jsonb_typeof(payload->''confirmed'') IS DISTINCT FROM ''boolean'' THEN RAISE EXCEPTION ''boolean confirmation required''; END IF;
 IF payload ? ''fence_retired'' AND jsonb_typeof(payload->''fence_retired'') IS DISTINCT FROM ''boolean'' THEN RAISE EXCEPTION ''boolean retirement required''; END IF;
 i:=v.intent;']]
 END;
 FOREACH pair SLICE 1 IN ARRAY patches LOOP
  IF position(pair[1] IN b)=0 THEN RAISE EXCEPTION 'missing patch anchor in %: %',sig,pair[1]; END IF;
  b:=replace(b,pair[1],pair[2]);
 END LOOP;
 EXECUTE b;
 END LOOP;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
