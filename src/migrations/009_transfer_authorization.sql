\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
SELECT pg_advisory_xact_lock(741903);

-- Preserve retained handler identities and ACLs while fixing the authorization
-- boundary. Admission alone cannot protect against a subsequently closed target.
DO $$ DECLARE b text; anchor text; BEGIN
 b:=pg_get_functiondef('api.accept(uuid,text,text,jsonb)'::regprocedure);
 anchor:='SELECT * INTO STRICT dest FROM api.container_content WHERE tenant_id=t AND id=(x->>''destination'')::uuid;
 l:=api.place(t,h.container_id);';
 IF position(anchor IN b)=0 THEN RAISE EXCEPTION 'missing transfer command destination anchor'; END IF;
 b:=replace(b,anchor,'SELECT * INTO STRICT dest FROM api.container_content WHERE tenant_id=t AND id=(x->>''destination'')::uuid;
 IF dest.closed THEN RAISE EXCEPTION ''closed transfer destination''; END IF;
 l:=api.place(t,h.container_id);');
 EXECUTE b;

 b:=pg_get_functiondef('api.usability(uuid,numeric,text)'::regprocedure);
 anchor:='BEGIN
 SELECT * INTO STRICT h';
 IF position(anchor IN b)=0 THEN RAISE EXCEPTION 'missing usability validation anchor'; END IF;
 b:=replace(b,anchor,'BEGIN
 IF intended_use IS NULL OR btrim(intended_use)='''' THEN RAISE EXCEPTION ''nonempty intended use required''; END IF;
 SELECT * INTO STRICT h');
 anchor:='ELSIF intended_use<>''transfer'' THEN';
 IF position(anchor IN b)=0 THEN RAISE EXCEPTION 'missing intended-use comparison anchor'; END IF;
 b:=replace(b,anchor,'ELSIF intended_use IS DISTINCT FROM ''transfer'' THEN');
 EXECUTE b;
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
