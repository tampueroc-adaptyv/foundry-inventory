\set ON_ERROR_STOP on
BEGIN;
SET ROLE modelj_owner;
-- Isolated administrative enrollment. Never granted to API identities.
CREATE FUNCTION api.fixture_id(k text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT md5(k)::uuid $$;
DO $$
DECLARE t text; i integer; w uuid; h uuid; qc uuid; run uuid; outid uuid; loc uuid;
BEGIN
 FOREACH t IN ARRAY ARRAY['a','b'] LOOP
 INSERT INTO api.material_spec_catalog VALUES(t,'protein@1',1,'v1','{"dimension":"volume","identity":"preparation","storage_required":false}'),(t,'target@1',1,'v1','{"dimension":"volume","identity":"preparation"}'),(t,'qc-protein@1',1,'v1','{"dimension":"volume","qc_spec":"qc@1"}');
 INSERT INTO api.container_spec_catalog VALUES(t,'plate384@1',1,'v1','{"rows":16,"columns":24,"direct_material":false}'),(t,'well@1',1,'v1','{"direct_material":true,"fixed":true}'),(t,'tube@1',1,'v1','{"direct_material":true}');
 INSERT INTO api.location_spec_catalog VALUES(t,'lab@1',1,'v1','{"storage_evidence_required":false}');
 INSERT INTO api.observation_specification_catalog VALUES(t,'binding-dataset@1',1,'v1','{"format":"binding-curves@1","members":384}'),(t,'qc-evidence@1',1,'v1','{"format":"enrollment-qc@1"}');
 INSERT INTO api.assessment_specification_catalog VALUES(t,'binding-fit@3',3,'v1','{"observation_spec":"binding-dataset@1","method":"reported-fit@1"}'),(t,'binding-fit@4',4,'v1','{"observation_spec":"binding-dataset@1","method":"reported-fit@2"}'),(t,'qc@1',1,'v1','{"observation_spec":"qc-evidence@1","method":"operator-review@1"}'),(t,'completion@1',1,'v1','{"observation_spec":"binding-dataset@1","method":"operator-review@1"}');
 INSERT INTO api.task_spec_catalog VALUES
 (t,'receipt@1',1,'v1','{"kind":"receipt","ports":["receipt","terminal"],"required_ports":["receipt"],"completion_assessment":"completion@1"}'),
 (t,'transfer@1',1,'v1','{"kind":"transfer","ports":["command","settlement","terminal","checkpoint"],"required_ports":["command","checkpoint"],"recovery":"settlement"}'),
 (t,'acquisition@1',1,'v1','{"kind":"acquisition","ports":["acquisition","terminal"],"required_ports":["acquisition"],"observation_spec":"binding-dataset@1","completion_assessment":"completion@1","cross_task":true}'),
 (t,'processing@3',3,'v1','{"kind":"interpretation","ports":["interpretation","terminal"],"required_ports":["interpretation"],"assessment_spec":"binding-fit@3"}'),
 (t,'processing@4',4,'v1','{"kind":"interpretation","ports":["interpretation","terminal"],"required_ports":["interpretation"],"assessment_spec":"binding-fit@4"}'),
 (t,'review@1',1,'v1','{"kind":"review","ports":["review","transition","terminal"],"assessment_spec":"completion@1","cross_task":true}'),
 (t,'correction@1',1,'v1','{"kind":"correction","ports":["correction","terminal"]}'),
 (t,'composite@1',1,'v1','{"kind":"composite","ports":["coordination","terminal"],"required_ports":["coordination"]}');
 -- Two sites and three workcells per tenant; location topology immutable in this slice.
 INSERT INTO api.location(tenant_id,id,spec_id,name,site,workcell) VALUES
 (t,api.fixture_id(t||'loc1'),'lab@1','primary','site1','w1'),(t,api.fixture_id(t||'loc2'),'lab@1','other-cell','site1','w2'),(t,api.fixture_id(t||'loc3'),'lab@1','remote','site2','w3');
 INSERT INTO api.material(tenant_id,id,spec_id,label,identity) VALUES(t,api.fixture_id(t||'protein'),'protein@1','protein preparation','{"lot":"P1"}'),(t,api.fixture_id(t||'target'),'target@1','target preparation','{"lot":"T1"}');
 INSERT INTO api.container(tenant_id,id,spec_id,barcode,location_id) VALUES(t,api.fixture_id(t||'plate'),'plate384@1',t||'-plate',api.fixture_id(t||'loc1'));
 -- Explicit provenance for enrollment evidence, not an invented acquisition/physical action.
 INSERT INTO api.task(tenant_id,id,spec_id,request_key,intent) VALUES(t,api.fixture_id(t||'enrollment-task'),'review@1','enrollment','{"administrative_enrollment":true}');
 INSERT INTO api.task_execution(tenant_id,id,task_id,spec_id,attempt,workcell) VALUES(t,api.fixture_id(t||'enrollment-execution'),api.fixture_id(t||'enrollment-task'),'review@1',1,'w1');
 INSERT INTO api.task_execution_output(tenant_id,id,execution_id,spec_id,request_key,port,request,payload,actor) VALUES(t,api.fixture_id(t||'enrollment-output'),api.fixture_id(t||'enrollment-execution'),'review@1','enrollment','review','{}','{"administrative_enrollment":true}','administrator');
 INSERT INTO api.observation(tenant_id,id,output_id,spec_id,artifact,mapping) VALUES(t,api.fixture_id(t||'qc-observation'),api.fixture_id(t||'enrollment-output'),'qc-evidence@1','{"version":"enrollment-1","format":"enrollment-qc@1"}','[{"member":"qc"}]');
 FOR i IN 1..384 LOOP
 w:=api.fixture_id(t||'well'||i); h:=api.fixture_id(t||'holding'||i);
 INSERT INTO api.container(tenant_id,id,spec_id,parent_id,position,fixed) VALUES(t,w,'well@1',api.fixture_id(t||'plate'),chr(65+(i-1)/24)||lpad((((i-1)%24)+1)::text,2,'0'),true);
 INSERT INTO api.container_content(tenant_id,id,material_id,container_id,dimension) VALUES(t,h,api.fixture_id(t||'protein'),w,'volume');
 INSERT INTO api.assessment(tenant_id,id,output_id,member,spec_id,subject_type,subject_id,subject,result,observation_id,observation_member) VALUES(t,api.fixture_id(t||'qc'||i),api.fixture_id(t||'enrollment-output'),'qc'||i,'qc@1','holding',h,jsonb_build_object('holding',h),'{"outcome":"pass"}',api.fixture_id(t||'qc-observation'),'qc');
 END LOOP;
 INSERT INTO api.material(tenant_id,id,spec_id,label,identity) VALUES(t,api.fixture_id(t||'qc-protein'),'qc-protein@1','QC governed preparation','{"lot":"Q1"}');
 FOR i IN 385..386 LOOP
 INSERT INTO api.container(tenant_id,id,spec_id,barcode,location_id) VALUES(t,api.fixture_id(t||'well'||i),'tube@1',t||'-tube-'||i,api.fixture_id(t||'loc1'));
 INSERT INTO api.container_content(tenant_id,id,material_id,container_id,dimension) VALUES(t,api.fixture_id(t||'holding'||i),api.fixture_id(t||'qc-protein'),api.fixture_id(t||'well'||i),'volume');
 INSERT INTO api.assessment(tenant_id,id,output_id,member,spec_id,subject_type,subject_id,subject,result,observation_id,observation_member,dependencies) VALUES(t,api.fixture_id(t||'qc'||i),api.fixture_id(t||'enrollment-output'),'qc'||i,'qc@1','holding',api.fixture_id(t||'holding'||i),jsonb_build_object('holding',api.fixture_id(t||'holding'||i)),'{"outcome":"pass"}',api.fixture_id(t||'qc-observation'),'qc',ARRAY[api.fixture_id(t||'qc'||(i-384))]);
 END LOOP;
 END LOOP;
END $$;
COMMIT;
