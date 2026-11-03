\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
CREATE UNIQUE INDEX unique_count_use ON api.task_execution_output_entity(tenant_id,target_id,selector) WHERE role='count-use';
CREATE FUNCTION api.balance_integrity() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM api.material_balance b WHERE b.tenant_id=NEW.tenant_id AND b.holding_id=NEW.holding_id AND (b.amount<0 OR b.amount<>(SELECT coalesce(sum(delta),0) FROM api.material_posting p WHERE p.tenant_id=b.tenant_id AND p.holding_id=b.holding_id))) THEN RAISE EXCEPTION 'negative or inconsistent balance'; END IF; RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER balance_integrity AFTER INSERT OR UPDATE ON api.material_balance DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.balance_integrity();
CREATE FUNCTION api.output_integrity() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,api AS $$
DECLARE n integer; expected integer; k text; v api.observation; a api.assessment;
BEGIN
 -- Administrative enrollment is the only bootstrap exemption and is not an RPC port.
 IF NEW.payload->>'administrative_enrollment'='true' AND NEW.actor='administrator' THEN RETURN NULL; END IF;
 IF NEW.port='receipt' THEN
 IF (SELECT count(*) FROM api.material_movement WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id)<>1 THEN RAISE EXCEPTION 'missing receipt movement'; END IF;
 ELSIF NEW.port='acquisition' THEN
 SELECT * INTO STRICT v FROM api.observation WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id;
 IF v.mapping<>NEW.payload->'mapping' OR v.artifact<>NEW.payload->'artifact' OR (SELECT count(*) FROM api.task_execution_output_entity WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id)<>jsonb_array_length(v.mapping)*5 THEN RAISE EXCEPTION 'incomplete observation relationships'; END IF;
 ELSIF NEW.port='interpretation' THEN
 expected:=jsonb_array_length(NEW.payload->'results');
 IF (SELECT count(*) FROM api.assessment WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id)<>expected OR (SELECT count(*) FROM api.task_execution_output_entity WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id)<>expected*4 THEN RAISE EXCEPTION 'incomplete interpretation projection'; END IF;
 ELSIF NEW.port='review' THEN
 IF (SELECT count(*) FROM api.assessment WHERE tenant_id=NEW.tenant_id AND output_id=NEW.id)<>1 THEN RAISE EXCEPTION 'missing review projection'; END IF;
 ELSIF NEW.port='terminal' THEN
 IF NOT EXISTS(SELECT 1 FROM api.task_execution WHERE tenant_id=NEW.tenant_id AND id=NEW.execution_id AND terminal_output=NEW.id AND state=NEW.payload->>'state') THEN RAISE EXCEPTION 'terminal manifest/state mismatch'; END IF;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM api.task_execution WHERE tenant_id=NEW.tenant_id AND id=NEW.execution_id AND spec_id=NEW.spec_id) THEN RAISE EXCEPTION 'execution specification mismatch'; END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER complete_output AFTER INSERT ON api.task_execution_output DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION api.output_integrity();
CREATE FUNCTION api.register_receipt(request_key text,intent jsonb,workcell text,evidence text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
#variable_conflict use_variable
DECLARE t text:=api.guard(); v api.task; e uuid; o uuid;
BEGIN
 SELECT * INTO v FROM api.task WHERE tenant_id=t AND supplier=intent->>'supplier' AND delivery=intent->>'delivery' AND source_line=intent->>'line';
 IF FOUND THEN
 IF v.intent<>intent THEN RAISE EXCEPTION 'conflicting external delivery'; END IF;
 SELECT z.id INTO o FROM api.task_execution_output z JOIN api.task_execution ex ON (ex.tenant_id,ex.id)=(z.tenant_id,z.execution_id) WHERE z.tenant_id=t AND ex.task_id=v.id AND z.port='receipt';
 IF o IS NOT NULL THEN RETURN o; END IF;
 RAISE EXCEPTION 'existing receipt task requires explicit recovery';
 END IF;
 v.id:=api.create_task('receipt@1',request_key,intent);
 e:=api.start_execution(v.id,workcell);
 RETURN api.accept(e,'receipt','receipt',jsonb_build_object('confirmed',true,'evidence',evidence));
END $$;
CREATE FUNCTION api.verify_balances() RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
DECLARE t text:=api.guard(); BEGIN
 RETURN NOT EXISTS(SELECT 1 FROM api.container_content h LEFT JOIN api.material_balance b ON (b.tenant_id,b.holding_id)=(h.tenant_id,h.id) WHERE h.tenant_id=t AND (b.holding_id IS NULL OR b.amount IS DISTINCT FROM (SELECT coalesce(sum(p.delta),0) FROM api.material_posting p WHERE p.tenant_id=t AND p.holding_id=h.id)));
END $$;
CREATE FUNCTION api.rebuild_balances() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER VOLATILE SET search_path=pg_catalog,api AS $$
DECLARE t text:=api.guard(); n integer;
BEGIN
 INSERT INTO api.material_balance(tenant_id,holding_id,amount,seq)
 SELECT t,h.id,coalesce(sum(p.delta),0),1 FROM api.container_content h LEFT JOIN api.material_posting p ON p.tenant_id=h.tenant_id AND p.holding_id=h.id WHERE h.tenant_id=t GROUP BY h.id
 ON CONFLICT(tenant_id,holding_id) DO UPDATE SET amount=excluded.amount,seq=api.material_balance.seq+1;
 GET DIAGNOSTICS n=ROW_COUNT;
 RETURN n;
END $$;
GRANT EXECUTE ON FUNCTION api.register_receipt(text,jsonb,text,text),api.verify_balances(),api.rebuild_balances() TO tenant_a,tenant_b;
COMMIT;
