"""Bounded 007/008 invariants through real HTTP, SQL COMMITs, races and faults."""
import concurrent.futures
import json
import pathlib
import sys
import threading
import unittest
import uuid
import urllib.request
import psycopg
from psycopg.types.json import Jsonb
from test_modelj import db, fid, http, DSN, API, token
from test_schema_consistency import apply, snapshot
from psycopg import sql as identifiers
from psycopg.conninfo import make_conninfo
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'scripts'))
from inventory_client import InventoryClient, APIError

ROOT=pathlib.Path(__file__).resolve().parents[1]


class Workflows(unittest.TestCase):
    def setUp(self):
        self.c=InventoryClient('tenant_b')
        self.loc={x['workcell']:x['id'] for x in self.c.request('/location') if x['workcell']}

    def reject(self, f):
        with self.assertRaises((APIError,psycopg.Error)):
            f()

    def admit(self,spec='assay@1',intent=None,key=None,ns='operator'):
        return self.c.rpc('admit_task',spec=spec,namespace=ns,request_key=key or self.c.key(),intent=intent or {})

    def start(self,t,key=None,wc='w1',selections=None):
        return self.c.rpc('start_task',task=t,namespace='scheduler',request_key=key or self.c.key(),workcell=wc,selections=selections or [])

    def accept(self,e,port,p,key=None):
        return self.c.rpc('accept',execution=e,request_key=key or self.c.key(),port=port,payload=p)

    def done(self,e):
        self.accept(e,'checkpoint',{'name':'verified','evidence':'reported assay checkpoint'})
        return self.accept(e,'terminal',{'state':'Completed','reason':'all required facts accepted'})

    def children(self,w):
        return self.c.rpc('workflow_progress',workflow=w)['children']

    def workflow(self,children=None,key=None):
        return self.c.rpc('create_workflow',namespace='operator',request_key=key or self.c.key(),children=children or [
            dict(name='a',role='first',spec='assay@1',intent={}),dict(name='b',role='second',spec='assay@1',intent={})])

    def pair(self,wc='w1'):
        hs=[]
        for _ in range(2):
            con=self.c.container(self.loc[wc],wc=wc)['container']
            hs.append(self.c.holding(str(fid('bprotein')),con,wc=wc)['holding'])
        self.c.rpc('register_receipt',request_key=self.c.key(),intent=dict(supplier='scope-source',delivery=self.c.key(),line='1',lot='L1',coa={},holding=hs[0],quantity=20,unit='uL'),workcell=wc,evidence='signed receipt')
        return hs

    def transfer_intent(self,pair,occurrence=None):
        return dict(items=[dict(key='one',source=pair[0],destination=pair[1],quantity=5,unit='uL')],semantic=dict(namespace='trusted-operation',occurrence=occurrence or self.c.key()))

    def command(self,e,key=None):
        return self.accept(e,'command',dict(command_id=self.c.key(),protocol='external-fence-v1'),key)

    def settle(self,e,cmd,outcome='full',key=None):
        return self.accept(e,'settlement',dict(command=cmd,key='one',outcome=outcome,quantity=0 if outcome=='zero' else 5,evidence='independent log',fence_retired=True),key)

    def test_01_admission_replicates_and_independent_start(self):
        key=self.c.key();t=self.admit(key=key)
        self.assertEqual(t,self.admit(key=key))
        self.reject(lambda:self.admit(intent={'parameters':{'x':1}},key=key))
        t2=self.admit();self.assertNotEqual(t,t2)
        self.assertEqual(self.c.request('/task_execution?task_id=eq.'+t),[])
        sk=self.c.key();e=self.start(t,sk);o=self.done(e)
        self.assertEqual(e,self.start(t,sk))
        self.reject(lambda:self.start(t2,sk))
        self.reject(lambda:self.start(t,sk,wc='w2'))
        self.assertNotEqual(e,self.start(t))
        self.assertEqual(self.c.output(o)['payload']['state'],'Completed')

    def test_02_physical_admission_defers_transient_readiness(self):
        pair=self.pair();e=self.start(self.admit('scoped-transfer-task@1',self.transfer_intent(pair)))
        cmd=self.command(e)
        # Pending resource must not prevent planned work admission.
        i=dict(source=pair[0],quantity=1,unit='uL',reason='planned waste')
        t=self.admit('dispose@1',i)
        self.assertEqual(self.c.request('/task_execution?task_id=eq.'+t),[])
        self.settle(e,cmd,'zero')
        later=self.start(t)
        self.assertTrue(later)
        self.assertEqual(self.c.rpc('open_inventory_task',spec='dispose@1',request_key='compat-'+self.c.key(),intent=i,workcell='w1') is not None,True)

    def test_03_start_and_event_races(self):
        k=self.c.key();bar=threading.Barrier(2)
        def admit(_):bar.wait();return self.admit(key=k,ns='external-event')
        with concurrent.futures.ThreadPoolExecutor(2) as p: ts=list(p.map(admit,range(2)))
        self.assertEqual(ts[0],ts[1])
        k=self.c.key();bar=threading.Barrier(2)
        def start(_):bar.wait();return self.start(ts[0],k)
        with concurrent.futures.ThreadPoolExecutor(2) as p: es=list(p.map(start,range(2)))
        self.assertEqual(es[0],es[1])
        self.assertEqual(len(self.c.request('/task_execution?task_id=eq.'+ts[0])),1)

    def test_04_authenticated_issuer_and_namespace(self):
        key=self.c.key();args=dict(spec='assay@1',namespace='event',request_key=key,intent={})
        status,a=http('/rpc/admit_task',args,role='tenant_b',sub='producer-a')
        status2,b=http('/rpc/admit_task',args,role='tenant_b',sub='producer-b')
        self.assertEqual((status,status2),(200,200));self.assertNotEqual(a,b)
        self.assertEqual(http('/rpc/admit_task',args,role='tenant_b',sub='producer-a')[1],a)
        status,_=http('/rpc/admit_task',{**args,'issuer':'producer-a'},role='tenant_b')
        self.assertGreaterEqual(status,400)
        self.assertNotEqual(self.admit(key=key,ns='another'),a)

    def test_05_workflow_http_sequential_parallel_and_reselection(self):
        plan=[dict(name='a',role='first',spec='assay@1',intent={}),dict(name='b',role='second',spec='assay@1',intent={},after=[dict(child='a',port='terminal',mode='historical')]),dict(name='c',role='second',spec='assay@1',intent={})]
        key=self.c.key();w=self.workflow(plan,key);self.assertEqual(w,self.workflow(plan,key))
        self.assertEqual(self.c.request('/workflow?id=eq.'+w)[0]['id'],w)
        self.assertTrue(self.c.request('/workflow_specification'))
        self.assertFalse(self.c.rpc('workflow_progress',workflow=w)['current_complete'])
        children=self.children(w);a,b,c=children
        coord=self.start(w)
        self.reject(lambda:self.start(b['task']))
        ae=self.start(a['task']);ce=self.start(c['task']);ao=self.done(ae);co=self.done(ce)
        be=self.start(b['task'],selections=[dict(role='a',execution=ae,output=ao)]);bo=self.done(be)
        selections=[dict(role=x['name'],port='terminal',execution=e,output=o) for x,e,o in [(a,ae,ao),(b,be,bo),(c,ce,co)]]
        old=self.c.rpc('evaluate_workflow',execution=coord,request_key='evaluate',selections=selections)
        snapshot=self.c.output(old)
        self.c.finish(coord)
        self.assertEqual(self.c.request('/workflow?id=eq.'+w)[0]['state'],'Pending')
        ae2=self.start(a['task']);ao2=self.done(ae2);coord2=self.start(w)
        selections[0]={**selections[0],'execution':ae2,'output':ao2}
        newer=self.c.rpc('evaluate_workflow',execution=coord2,request_key='reevaluate',selections=selections,complete_task=True,expected_seq=0)
        self.assertNotEqual(old,newer);self.assertEqual(snapshot,self.c.output(old))
        self.assertTrue(self.c.rpc('workflow_progress',workflow=w)['current_complete'])
        self.assertEqual(coord2,self.start(w,key=self.c.request('/task_execution?id=eq.'+coord2)[0]['start_key']))
        self.assertEqual(self.c.rpc('evaluate_workflow',execution=coord2,request_key='reevaluate',selections=selections,complete_task=True,expected_seq=0),newer)
        self.reject(lambda:self.accept(coord2,'coordination',{'selections':[]}))
        self.assertEqual(http('/workflow?id=eq.'+w,role='tenant_a')[1],[])

    def test_06_bad_membership_cycles_nesting_and_replanning(self):
        valid=[dict(name='a',role='first',spec='assay@1',intent={}),dict(name='b',role='second',spec='assay@1',intent={})]
        for bad in [valid[:1],valid+[valid[0]], [{**valid[0],'spec':'bounded-workflow@1'},valid[1]], [{**valid[0],'task':str(fid('aenrollment-task'))},valid[1]], [{**valid[0],'role':'unknown'},valid[1]], [{**valid[0],'spec':'receipt@1'},valid[1]], [{**valid[0],'owner_task':str(uuid.uuid4())},valid[1]]]:
            self.reject(lambda:self.workflow(bad))
        cycle=[{**valid[0],'after':[dict(child='b',port='terminal',mode='historical')]},{**valid[1],'after':[dict(child='a',port='terminal',mode='historical')]}]
        self.reject(lambda:self.workflow(cycle))
        self.reject(lambda:self.admit(intent={'replacement':str(uuid.uuid4())}))
        w=self.workflow();child=self.children(w)[0]
        with self.assertRaises(psycopg.Error):
            with db(None) as c:c.execute('UPDATE api.task SET owner_task=NULL WHERE id=%s',[child['task']])
        # Deferred reciprocal ownership is checked at actual COMMIT.
        with self.assertRaises(psycopg.Error):
            with db(None) as c:c.execute("INSERT INTO api.task(tenant_id,spec_id,request_key,intent,owner_task) VALUES('b','assay@1',%s,'{}',%s)",[self.c.key(),w])

    def test_07_workflow_local_two_children(self):
        occurrence=self.c.key();pairs=[self.pair(),self.pair()]
        plan=[dict(name='a',role='first',spec='scoped-transfer-workflow@1',intent=self.transfer_intent(pairs[0],occurrence)),dict(name='b',role='second',spec='scoped-transfer-workflow@1',intent=self.transfer_intent(pairs[1],occurrence))]
        w=self.workflow(plan);children=self.children(w);es=[self.start(x['task']) for x in children]
        self.reject(lambda:self.command(es[0])) # no accepted membership yet
        self.start(w);bar=threading.Barrier(2)
        def authorize(e):
            bar.wait()
            try:return self.command(e)
            except APIError:return None
        with concurrent.futures.ThreadPoolExecutor(2) as p:result=list(p.map(authorize,es))
        self.assertEqual(sum(x is not None for x in result),1)
        winner=0 if result[0] else 1;self.settle(es[winner],result[winner])
        self.reject(lambda:self.command(es[1-winner]))
        self.assertEqual(len(self.c.request('/task_execution_output_entity?role=eq.semantic-claim&scope_identity=eq.'+w)),2)

    def test_08_site_local_across_workflows_and_upgrade(self):
        occ=self.c.key();pairs=[self.pair(),self.pair()];es=[]
        for pair,version in zip(pairs,[1,2]):
            w=self.workflow([dict(name='effect',role='first',spec='scoped-transfer-site@'+str(version),intent=self.transfer_intent(pair,occ)),dict(name='assay',role='second',spec='assay@1',intent={})])
            self.start(w);es.append(self.start(self.children(w)[0]['task']))
        cmd=self.command(es[0]);self.settle(es[0],cmd)
        self.reject(lambda:self.command(es[1]))
        # Same site key is allowed at another validated site only by this policy.
        t=self.admit('scoped-transfer-site@2',self.transfer_intent(self.pair('w3'),occ));self.command(self.start(t,wc='w3'))
        with self.assertRaises(psycopg.Error):
            with db(None) as c:c.execute("INSERT INTO api.task_spec_catalog(tenant_id,id,version,handler,definition) VALUES('b','scoped-transfer-site@3',3,'v1',%s)",[Jsonb({'kind':'transfer','semantic':{'scope':'tenant','family':'new-escape'}})])

    def test_09_tenant_receiving_across_sites_and_repeatable_assays(self):
        hs=[self.pair()[0],self.pair('w3')[0]];delivery=self.c.key()
        i=dict(supplier='global-receiver',delivery=delivery,line='1',lot='L1',coa={},holding=hs[0],quantity=1,unit='uL')
        out=self.c.rpc('register_receipt',request_key=self.c.key(),intent=i,workcell='w1',evidence='signed')
        self.assertEqual(out,self.c.rpc('register_receipt',request_key=self.c.key(),intent=i,workcell='w3',evidence='retry'))
        self.reject(lambda:self.c.rpc('register_receipt',request_key=self.c.key(),intent={**i,'holding':hs[1]},workcell='w3',evidence='other site'))
        claims=self.c.request('/task_execution_output_entity?output_id=eq.'+out+'&role=eq.semantic-claim')
        self.assertEqual({x['claim_phase'] for x in claims},{'ownership','settlement'})
        owner=next(x for x in claims if x['claim_phase']=='ownership');settle=next(x for x in claims if x['claim_phase']=='settlement')
        self.assertEqual(settle['ownership_id'],owner['claim_id']);self.assertEqual(owner['scope_identity'],'b')
        # Separate assay identities do not inherit receiving/transfer uniqueness.
        ts=[self.admit(intent={'parameters':{'assay':'identical'}}) for _ in range(2)]
        self.assertNotEqual(*ts)
        for t in ts:self.done(self.start(t))

    def test_10_tenant_transfer_across_sites(self):
        occ=self.c.key();es=[]
        for wc in ['w1','w3']:
            t=self.admit('scoped-transfer-tenant@1',self.transfer_intent(self.pair(wc),occ));es.append(self.start(t,wc=wc))
        self.command(es[0]);self.reject(lambda:self.command(es[1]))

    def test_11_failed_late_settlement_and_retry_ownership(self):
        pair=self.pair();t=self.admit('scoped-transfer-task@1',self.transfer_intent(pair));sk=self.c.key();e=self.start(t,sk);cmd=self.command(e)
        self.settle(e,cmd,'unknown');term=self.c.finish(e,'Failed');snapshot=self.c.output(term)
        self.assertEqual(e,self.start(t,sk))
        e2=self.start(t)
        self.reject(lambda:self.settle(e2,cmd)) # a new attempt is not automatically recovery authority
        self.reject(lambda:self.command(e2))
        out=self.settle(e,cmd,key='late');self.assertEqual(out,self.settle(e,cmd,key='late'))
        self.reject(lambda:self.settle(e,cmd))
        self.assertEqual(snapshot,self.c.output(term));self.assertEqual(self.c.current(pair[0])['recorded_quantity'],15)
        self.assertTrue(self.c.rpc('verify_balances'))

    def test_12_claim_rollback_and_relational_identity(self):
        pair=self.pair();e=self.start(self.admit('scoped-transfer-site@1',self.transfer_intent(pair)))
        with db(None) as c:
            c.execute("CREATE OR REPLACE FUNCTION api.claim_test_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.role='semantic-claim' THEN RAISE EXCEPTION 'claim fault'; END IF; RETURN NEW; END $$")
            c.execute('CREATE TRIGGER claim_test_fault AFTER INSERT ON api.task_execution_output_entity FOR EACH ROW EXECUTE FUNCTION api.claim_test_fault()')
        before=self.c.request('/task_execution_output?execution_id=eq.'+e)
        try:self.reject(lambda:self.command(e))
        finally:
            with db(None) as c:c.execute('DROP TRIGGER claim_test_fault ON api.task_execution_output_entity')
        self.assertEqual(before,self.c.request('/task_execution_output?execution_id=eq.'+e))
        cmd=self.command(e);own=self.c.request('/task_execution_output_entity?output_id=eq.'+cmd+'&role=eq.semantic-claim')[0]
        # Owner can test typed FK at COMMIT; no forged row survives. New output
        # ensures this tests identity linkage rather than merely sealing.
        with self.assertRaises(psycopg.errors.ForeignKeyViolation):
            with db(None) as c:
                o=c.execute("INSERT INTO api.task_execution_output(tenant_id,execution_id,spec_id,request_key,port,request,payload,actor) VALUES('b',%s,'scoped-transfer-site@1',%s,'checkpoint','{}','{}','test') RETURNING id",[e,self.c.key()]).fetchone()[0]
                c.execute("INSERT INTO api.task_execution_output_entity(tenant_id,output_id,member,role,target_type,target_id,selector,claim_id,claim_phase,semantic_family,scope_kind,scope_identity,consequence_key,policy_pin,ownership_id,ownership_phase) VALUES('b',%s,'one','semantic-claim','task',%s,'settlement',pg_catalog.uuidv7(),'settlement',%s,'site',%s,'mismatched-key',%s,%s,'ownership')",[o,own['target_id'],own['semantic_family'],own['scope_identity'],own['policy_pin'],own['claim_id']])
                c.execute('SET CONSTRAINTS api.settlement_ownership IMMEDIATE')
        # Existing output cannot acquire a late extra relationship.
        with self.assertRaises(psycopg.Error):
            with db(None) as c:c.execute("INSERT INTO api.task_execution_output_entity(tenant_id,output_id,member,role,target_type,target_id) VALUES('b',%s,'extra','evidence','task',%s)",[cmd,own['target_id']])
        self.settle(e,cmd)

    def test_13_scope_pinning_and_disabled_workcell(self):
        pair=self.pair();t=self.admit('scoped-transfer-site@1',self.transfer_intent(pair));e=self.start(t);cmd=self.command(e)
        policy=self.c.request('/task?id=eq.'+t)[0]['semantic_policy'];container=self.c.current(pair[0])['container_id']
        # Controlled fixture topology change: no cross-site logistics API added.
        with db(None) as c:c.execute('UPDATE api.container SET location_id=%s WHERE id=%s',[self.loc['w3'],container])
        self.settle(e,cmd)
        self.assertEqual(self.c.request('/task?id=eq.'+t)[0]['semantic_policy'],policy)
        claims=self.c.request('/task_execution_output_entity?output_id=eq.'+cmd+'&role=eq.semantic-claim')
        self.assertEqual(claims[0]['scope_identity'],policy['identity'])
        self.reject(lambda:self.admit('scoped-transfer-workcell@1',self.transfer_intent(self.pair())))
        with self.assertRaises(psycopg.Error):
            with db(None) as c:c.execute('UPDATE api.task SET semantic_policy=\'{}\' WHERE id=%s',[t])

    def test_14_dependency_cross_task_completion_and_shared_consumption(self):
        # Use the original scientific RPCs, then consume a transition whose
        # actual producer is the independent review Task, not the assessed Task.
        mapping=[dict(member=chr(65+(i-1)//24)+f'{(i-1)%24+1:02}',holding=str(fid('bholding'+str(i))),well=str(fid('bwell'+str(i))),protein=str(fid('bprotein')),target=str(fid('btarget')),basis=str(fid('bqc'+str(i)))) for i in range(1,385)]
        target=self.c.rpc('create_task',spec='acquisition@1',request_key=self.c.key(),intent={'plate':str(fid('bplate')),'mapping':mapping});ae=self.c.rpc('start_execution',task=target,workcell='w1')
        ao=self.accept(ae,'acquisition',dict(mapping=mapping,artifact=dict(bucket='mock',key='curves',version='v1',sha256='a'*64,format='binding-curves@1',size=10)))
        obs=self.c.request('/observation?output_id=eq.'+ao)[0]['id'];intent=dict(observation=obs,member='A01',subject=target,subject_type='task')
        review=self.c.rpc('create_task',spec='review@1',request_key=self.c.key(),intent=intent);re=self.c.rpc('start_execution',task=review,workcell='w1')
        ro=self.accept(re,'review',{**intent,'outcome':'pass'});assessment=self.c.request('/assessment?output_id=eq.'+ro)[0]['id']
        transition=self.accept(re,'transition',dict(target=target,assessment=assessment,expected_seq=0))
        deps=[dict(role='approved',task=target,spec='acquisition@1',port='transition',mode='historical')]
        downstream=self.admit(intent={'dependencies':deps});self.reject(lambda:self.start(downstream))
        de=self.start(downstream,selections=[dict(role='approved',execution=re,output=transition)])
        invocation=self.c.request('/task_execution?id=eq.'+de)[0]['invocation']['dependencies'][0]
        self.assertEqual(invocation['task'],target);self.assertEqual(invocation['producer_task'],review)
        self.assertEqual(self.c.request('/task?id=eq.'+target)[0]['owner_task'],None)
        self.assertEqual(self.c.request('/task?id=eq.'+downstream)[0]['intent']['dependencies'],deps)
        self.reject(lambda:self.start(downstream,selections=[dict(role='approved',execution=ae,output=transition)]))

    def test_15_openapi_matches_live_public_contracts(self):
        with urllib.request.urlopen(urllib.request.Request(API+'/',headers={'Authorization':'Bearer '+token('tenant_b'),'Accept':'application/openapi+json'})) as r:live=json.load(r)
        for path in ['/workflow','/workflow_specification','/rpc/create_workflow','/rpc/start_task','/rpc/evaluate_workflow','/rpc/workflow_progress','/rpc/admit_task']:
            self.assertIn(path,live['paths'])
        artifact=json.loads((ROOT/'docs/openapi.json').read_text())
        self.assertEqual(live['paths'],artifact['paths']);self.assertEqual(live['definitions'],artifact['definitions'])
        self.assertEqual(self.c.rpc('verify_balances'),True)

    def test_16_populated_005_forward_upgrade_and_legacy_retry(self):
        name='modelj_forward_'+uuid.uuid4().hex
        admin=psycopg.connect(DSN,autocommit=True);c=None
        try:
            admin.execute(identifiers.SQL('CREATE DATABASE {}').format(identifiers.Identifier(name)))
            c=psycopg.connect(make_conninfo(DSN,dbname=name),autocommit=True)
            first=(ROOT/'migrations/001_schema.sql').read_text();first='BEGIN;\nCREATE SCHEMA api AUTHORIZATION modelj_owner;'+first.split('CREATE SCHEMA api AUTHORIZATION modelj_owner;',1)[1]
            apply(c,first)
            for f in ['002_handlers.sql','003_integrity_and_rpc.sql','004_physical_inventory.sql','005_schema_consistency.sql']:apply(c,(ROOT/'migrations'/f).read_text())
            apply(c,(ROOT/'fixtures/seed.sql').read_text());c.execute('SET ROLE tenant_b')
            i=dict(supplier='old-source',delivery='old-delivery',line='1',lot='L1',coa={},holding=str(fid('bholding1')),quantity=10,unit='uL')
            old=c.execute('SELECT api.register_receipt(%s,%s,%s,%s)',['old-key',Jsonb(i),'w1','signed']).fetchone()[0]
            c.execute('SET ROLE modelj_owner');before=snapshot(c)
            for f in ['006_validation.sql','007_initiation_workflows.sql']:apply(c,(ROOT/'migrations'/f).read_text())
            # An unattributable legacy source must abort policy activation, not
            # be silently certified. This is isolated administrator test data.
            bad=c.execute("INSERT INTO api.task(tenant_id,spec_id,request_key,intent) VALUES('b','receipt@1','ambiguous-legacy','{\"supplier\":null,\"delivery\":null,\"line\":null}') RETURNING id").fetchone()[0]
            with self.assertRaisesRegex(psycopg.Error,'ambiguous legacy'):
                apply(c,(ROOT/'migrations/008_scoped_effects.sql').read_text())
            c.execute('ROLLBACK')
            self.assertEqual(c.execute("SELECT count(*) FROM api.location_spec_catalog WHERE id='semantic-site@1'").fetchone()[0],0)
            c.execute('ALTER TABLE api.task DISABLE TRIGGER frozen_work')
            c.execute('DELETE FROM api.task WHERE id=%s',[bad])
            c.execute('ALTER TABLE api.task ENABLE TRIGGER frozen_work')
            apply(c,(ROOT/'migrations/008_scoped_effects.sql').read_text())
            after=snapshot(c)
            # Every original field/accepted fact remains exactly equal; only new
            # projection metadata/catalog rows are added.
            for table,rows in before.items():
                for row in rows:
                    match=next(r for r in after[table] if all(r.get(k)==row[k] for k in (['tenant_id','id'] if 'id' in row else row.keys())))
                    for k,v in row.items():self.assertEqual(match[k],v,(table,k))
            c.execute('SET ROLE tenant_b')
            self.assertEqual(c.execute('SELECT api.register_receipt(%s,%s,%s,%s)',['another-key',Jsonb(i),'w1','retry']).fetchone()[0],old)
            self.assertEqual(c.execute("SELECT count(*) FROM api.task_execution_output_entity WHERE output_id=%s AND role='semantic-claim'",[old]).fetchone()[0],0)
            self.assertEqual(c.execute('SELECT api.verify_balances()').fetchone()[0],True)
            self.assertEqual(c.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='api' AND table_type='BASE TABLE'").fetchone()[0],19)
        finally:
            if c:c.close()
            admin.execute(identifiers.SQL('DROP DATABASE IF EXISTS {} WITH (FORCE)').format(identifiers.Identifier(name)));admin.close()

    def test_17_keyed_receiving_and_legacy_scope_activation_guard(self):
        pair=self.pair();i=dict(supplier='keyed-source',delivery=self.c.key(),line='1',lot='L1',coa={},holding=pair[0],quantity=1,unit='uL')
        k=self.c.key();t=self.admit('receipt@1',i,k);self.assertEqual(t,self.admit('receipt@1',i,k))
        e=self.start(t);out=self.accept(e,'receipt',{'confirmed':True,'evidence':'signed'})
        self.assertEqual(self.c.rpc('register_receipt',request_key=self.c.key(),intent=i,workcell='w1',evidence='retry'),out)
        # Scope used by an old unscoped physical command is not silently adopted.
        raw=self.transfer_intent(pair);raw.pop('semantic')
        old=self.c.rpc('create_task',spec='transfer@1',request_key=self.c.key(),intent=raw)
        oe=self.c.rpc('start_execution',task=old,workcell='w1');cmd=self.command(oe);self.settle(oe,cmd,'zero')
        self.reject(lambda:self.admit('scoped-transfer-site@1',self.transfer_intent(pair)))

    def test_18_forged_claims_and_claim_shape_reject(self):
        t=self.admit();e=self.start(t)
        # Internal claim encodings in public payloads cannot acquire ownership.
        self.accept(e,'checkpoint',{'name':'verified','evidence':'signed','semantic_claims':[{'phase':'ownership'}]})
        self.assertEqual(self.c.request('/task_execution_output_entity?target_id=eq.'+t+'&role=eq.semantic-claim'),[])
        with self.assertRaises(psycopg.errors.CheckViolation):
            with db(None) as c:
                o=c.execute("INSERT INTO api.task_execution_output(tenant_id,execution_id,spec_id,request_key,port,request,payload,actor) VALUES('b',%s,'assay@1',%s,'checkpoint','{}','{}','test') RETURNING id",[e,self.c.key()]).fetchone()[0]
                c.execute("INSERT INTO api.task_execution_output_entity(tenant_id,output_id,member,role,target_type,target_id,selector) VALUES('b',%s,'x','semantic-claim','task',%s,'ownership')",[o,t])

    def test_19_settlement_claim_fault_rolls_back_all(self):
        pair=self.pair();e=self.start(self.admit('scoped-transfer-task@1',self.transfer_intent(pair)));cmd=self.command(e)
        with db(None) as c:
            c.execute("CREATE OR REPLACE FUNCTION api.settlement_test_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.claim_phase='settlement' THEN RAISE EXCEPTION 'settlement fault'; END IF; RETURN NEW; END $$")
            c.execute('CREATE TRIGGER settlement_test_fault AFTER INSERT ON api.task_execution_output_entity FOR EACH ROW EXECUTE FUNCTION api.settlement_test_fault()')
        before=self.c.request('/task_execution_output?execution_id=eq.'+e)
        try:self.reject(lambda:self.settle(e,cmd,key='retry-settlement'))
        finally:
            with db(None) as c:c.execute('DROP TRIGGER settlement_test_fault ON api.task_execution_output_entity')
        self.assertEqual(before,self.c.request('/task_execution_output?execution_id=eq.'+e))
        self.assertEqual(self.c.current(pair[0])['recorded_quantity'],20)
        self.settle(e,cmd,key='retry-settlement');self.assertEqual(self.c.current(pair[0])['recorded_quantity'],15)

    def test_20_missing_extra_and_wrong_invocation_selection(self):
        w=self.workflow();children=self.children(w);coord=self.start(w)
        es=[self.start(x['task']) for x in children];outs=[self.done(e) for e in es]
        ss=[dict(role=x['name'],port='terminal',execution=e,output=o) for x,e,o in zip(children,es,outs)]
        for bad in [ss[:1],ss+[ss[0]],[{**ss[0],'member':'absent'},ss[1]],[{**ss[0],'execution':es[1]},ss[1]]]:
            self.reject(lambda:self.c.rpc('evaluate_workflow',execution=coord,request_key=self.c.key(),selections=bad))
        self.assertEqual(self.c.request('/task_execution_output?execution_id=eq.'+coord+'&port=eq.coordination'),[])
        # A shared dependency consumes an existing child result without ownership.
        dep=dict(role='shared',task=children[0]['task'],spec='assay@1',port='terminal',mode='historical')
        t=self.admit(intent={'dependencies':[dep]})
        self.reject(lambda:self.start(t,selections=[dict(role='shared',execution=es[0],output=outs[0],parameters={'override':True})]))
        self.start(t,selections=[dict(role='shared',execution=es[0],output=outs[0])])
        self.assertEqual(self.c.request('/task?id=eq.'+children[0]['task'])[0]['owner_task'],w)
        self.assertIsNone(self.c.request('/task?id=eq.'+t)[0]['owner_task'])

    def test_21_membership_evidence_must_be_complete(self):
        w=self.workflow();key=self.c.key()
        with db(None) as c:
            c.execute("CREATE OR REPLACE FUNCTION api.omit_member_test() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.role='owned-child' AND NEW.member='b' THEN RETURN NULL; END IF; RETURN NEW; END $$")
            c.execute('CREATE TRIGGER omit_member_test BEFORE INSERT ON api.task_execution_output_entity FOR EACH ROW EXECUTE FUNCTION api.omit_member_test()')
        try:self.reject(lambda:self.start(w,key))
        finally:
            with db(None) as c:c.execute('DROP TRIGGER omit_member_test ON api.task_execution_output_entity')
        self.assertEqual(self.c.request('/task_execution?task_id=eq.'+w),[])
        self.start(w,key)

    def test_22_missing_claim_rejected_at_commit(self):
        pair=self.pair();e=self.start(self.admit('scoped-transfer-task@1',self.transfer_intent(pair)))
        with db(None) as c:
            c.execute("CREATE OR REPLACE FUNCTION api.omit_claim_test() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.role='semantic-claim' THEN RETURN NULL; END IF; RETURN NEW; END $$")
            c.execute('CREATE TRIGGER omit_claim_test BEFORE INSERT ON api.task_execution_output_entity FOR EACH ROW EXECUTE FUNCTION api.omit_claim_test()')
        try:self.reject(lambda:self.command(e))
        finally:
            with db(None) as c:c.execute('DROP TRIGGER omit_claim_test ON api.task_execution_output_entity')
        self.assertEqual(self.c.request('/task_execution_output?execution_id=eq.'+e),[])
        self.command(e)

    def test_23_zero_cancellation_and_correction_never_recycle_claims(self):
        for outcome in ['zero','full']:
            occurrence=self.c.key();pair=self.pair()
            e=self.start(self.admit('scoped-transfer-site@1',self.transfer_intent(pair,occurrence)));cmd=self.command(e)
            out=self.settle(e,cmd,outcome);self.c.finish(e,'Canceled')
            if outcome=='full':
                movement=self.c.request('/material_movement?output_id=eq.'+out)[0]['id']
                correction=self.c.rpc('create_task',spec='correction@1',request_key=self.c.key(),intent={})
                ce=self.c.rpc('start_execution',task=correction,workcell='w1')
                self.accept(ce,'correction',dict(type='replace',original=movement,quantity=3,unit='uL',reason='correct reported amount'))
            contender=self.start(self.admit('scoped-transfer-site@2',self.transfer_intent(self.pair(),occurrence)))
            self.reject(lambda:self.command(contender))
        self.assertTrue(self.c.rpc('verify_balances'))

if __name__=='__main__':unittest.main(verbosity=2)
