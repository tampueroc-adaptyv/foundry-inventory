"""006 regressions. Each fixture transaction rolls back; rejected calls use savepoints."""
import unittest
import uuid
import psycopg
from psycopg.types.json import Jsonb
from test_modelj import db, fid


class Validation(unittest.TestCase):
    def setUp(self):
        self.ctx = db('tenant_b')
        self.c = self.ctx.__enter__()

    def tearDown(self):
        self.c.rollback()
        self.ctx.__exit__(None, None, None)

    def call(self, name, *args):
        return self.c.execute('SELECT api.' + name + '(' + ','.join(['%s']*len(args)) + ')',
                              [Jsonb(x) if isinstance(x, (dict, list)) else x for x in args]).fetchone()[0]

    def task(self, spec, intent):
        t = self.call('create_task', spec, str(uuid.uuid4()), intent)
        return t, self.call('start_execution', t, 'w1')

    def accept(self, e, port, p):
        return self.call('accept', e, str(uuid.uuid4()), port, p)

    def counts(self):
        return [self.c.execute('SELECT count(*) FROM api.'+t).fetchone()[0] for t in
                ['task','task_execution_output','assessment','material_movement','material_posting']] + [
                self.c.execute('SELECT sum(amount) FROM api.material_balance').fetchone()[0]]

    def rejects(self, fn):
        before = self.counts()
        with self.assertRaises(psycopg.Error):
            with self.c.transaction():
                fn()
                self.c.execute('SET CONSTRAINTS ALL IMMEDIATE')
        self.assertEqual(before, self.counts())

    def acquisition(self):
        mapping = [dict(member=chr(65+(i-1)//24)+f'{(i-1)%24+1:02}', holding=str(fid('bholding'+str(i))),
                        well=str(fid('bwell'+str(i))), protein=str(fid('bprotein')), target=str(fid('btarget')),
                        basis=str(fid('bqc'+str(i)))) for i in range(1,385)]
        t,e = self.task('acquisition@1', {'plate':str(fid('bplate')), 'mapping':mapping})
        p = {'mapping':mapping, 'artifact':dict(bucket='mock',key='run',version='v1',sha256='a'*64,format='binding-curves@1',size=10)}
        o = self.accept(e,'acquisition',p)
        obs = self.c.execute('SELECT id FROM api.observation WHERE output_id=%s',[o]).fetchone()[0]
        return t,e,obs,p

    def test_01_review_outcome_and_transition_are_positive(self):
        t,e,obs,_ = self.acquisition()
        intent = dict(observation=str(obs),member='A01',subject=str(t),subject_type='task')
        _,r = self.task('review@1',intent)
        for bad in [None, True, 1, {}, [], '', 'unsupported']:
            self.rejects(lambda: self.accept(r,'review',{**intent,'outcome':bad}))
        self.rejects(lambda: self.accept(r,'review',intent))
        self.rejects(lambda: self.accept(r,'review',None))  # SQL NULL
        ro = self.accept(r,'review',{**intent,'outcome':'fail'})
        a = self.c.execute('SELECT id FROM api.assessment WHERE output_id=%s',[ro]).fetchone()[0]
        self.rejects(lambda: self.accept(r,'transition',dict(target=str(t),assessment=str(a),expected_seq=0)))
        self.assertEqual(self.c.execute('SELECT state FROM api.task WHERE id=%s',[t]).fetchone()[0],'Pending')
        # A malformed pre-fix projection can exist in legacy history. Even it
        # must never satisfy the new positive transition predicate.
        # Clear legitimate output checks before inserting the historical fixture;
        # rejection must come from the transition, not an unrelated row count.
        self.c.execute('SET CONSTRAINTS ALL IMMEDIATE')
        # Use the owner only for the legacy fixture, never as the accepting RPC.
        self.c.execute('RESET ROLE')
        legacy = self.c.execute("INSERT INTO api.assessment(tenant_id,output_id,member,spec_id,subject_type,subject_id,subject,result,observation_id,observation_member) SELECT tenant_id,output_id,'legacy-null',spec_id,subject_type,subject_id,subject,jsonb_build_object('outcome',NULL),observation_id,observation_member FROM api.assessment WHERE id=%s RETURNING id",[a]).fetchone()[0]
        self.c.execute('SET ROLE tenant_b')
        self.rejects(lambda: self.accept(r,'transition',dict(target=str(t),assessment=str(legacy),expected_seq=0)))

    def test_02_transfer_protocol_required(self):
        intent = dict(supplier='valid',delivery=str(uuid.uuid4()),line='1',lot='L1',coa={},holding=str(fid('bholding1')),quantity=10,unit='uL')
        self.call('register_receipt',str(uuid.uuid4()),intent,'w1','signed')
        _,e = self.task('transfer@1',{'items':[dict(key='x',source=str(fid('bholding1')),destination=str(fid('bholding2')),quantity=1,unit='uL')]})
        for p in [{},None,{'protocol':None},{'protocol':True},{'protocol':'wrong'}]:
            self.rejects(lambda: self.accept(e,'command',None if p is None else {'command_id':str(uuid.uuid4()),**p}))
        self.accept(e,'command',dict(command_id=str(uuid.uuid4()),protocol='external-fence-v1'))
        self.c.execute('SET CONSTRAINTS ALL IMMEDIATE')

    def test_03_receiving_identity_required_and_typed(self):
        intent = dict(supplier='valid',delivery=str(uuid.uuid4()),line='1',lot='L1',coa={},holding=str(fid('bholding1')),quantity=10,unit='uL')
        for field in ['supplier','delivery','line']:
            for bad in [None,'','  ',True,1,{},[]]:
                self.rejects(lambda: self.call('register_receipt',str(uuid.uuid4()),{**intent,field:bad},'w1','signed'))
            p = {k:v for k,v in intent.items() if k!=field}
            self.rejects(lambda: self.call('register_receipt',str(uuid.uuid4()),p,'w1','signed'))
        self.rejects(lambda: self.call('create_task','receipt@1',str(uuid.uuid4()),None))
        self.rejects(lambda: self.call('create_task','receipt@1',str(uuid.uuid4()),{**intent,'quantity':None}))

    def test_04_artifact_null_and_numeric_null(self):
        _,e,_,p = self.acquisition()
        for field in p['artifact']:
            self.rejects(lambda: self.accept(e,'acquisition',{**p,'artifact':{**p['artifact'],field:None}}))
        self.rejects(lambda: self.call('normalized',None,'uL','volume'))
        # Combined-wrapper retry must not treat SQL NULL as equivalent input.
        i=dict(operation='container',spec='tube@1',barcode=str(uuid.uuid4()),location=str(fid('bloc1')),position=uuid.uuid4().hex[:20])
        key=str(uuid.uuid4()); self.call('open_inventory_task','inventory-register@1',key,i,'w1')
        self.rejects(lambda:self.call('open_inventory_task','inventory-register@1',key,i,None))
        self.rejects(lambda:self.call('open_inventory_task','inventory-register@1',key,None,'w1'))

if __name__ == '__main__': unittest.main(verbosity=2)
