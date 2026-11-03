"""Validation regressions. Fixture transactions roll back; rejected calls use savepoints."""
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

    def transfer_holdings(self):
        # Fresh holdings keep these tests independent of other suites' balances
        # and outstanding physical commands. All setup uses public RPCs.
        holdings = []
        for _ in range(2):
            e = self.call('open_inventory_task', 'inventory-register@1', str(uuid.uuid4()),
                          dict(operation='container', spec='tube@1', barcode=str(uuid.uuid4()),
                               location=str(fid('bloc1')), position=uuid.uuid4().hex), 'w1')
            o = self.call('inventory_accept', e, 'register', 'register', dict(confirmed=True, evidence='scanned tube'))
            container = self.c.execute("SELECT payload->>'container' FROM api.task_execution_output WHERE id=%s", [o]).fetchone()[0]
            e = self.call('open_inventory_task', 'inventory-register@1', str(uuid.uuid4()),
                          dict(operation='holding', container=container, material=str(fid('bprotein'))), 'w1')
            o = self.call('inventory_accept', e, 'register', 'register', dict(confirmed=True, evidence='verified holding'))
            holdings.append(self.c.execute("SELECT payload->>'holding' FROM api.task_execution_output WHERE id=%s", [o]).fetchone()[0])
        self.call('register_receipt', str(uuid.uuid4()),
                  dict(supplier='valid', delivery=str(uuid.uuid4()), line='1', lot='L1', coa={},
                       holding=holdings[0], quantity=10, unit='uL'), 'w1', 'signed receipt')
        return holdings

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

    def test_05_closed_destination_rejected_at_command_acceptance(self):
        for close_before_admission in [True, False]:
            with self.subTest(close_before_admission=close_before_admission):
                source, destination = self.transfer_holdings()
                _, correction = self.task('correction@1', {})

                def close():
                    self.accept(correction, 'correction', dict(type='close_holding', holding=destination))

                if close_before_admission:
                    close()
                task = self.call('admit_task', 'transfer@1', 'validation', str(uuid.uuid4()),
                                 {'items': [dict(key='x', source=source, destination=destination, quantity=1, unit='uL')]})
                e = self.call('start_task', task, 'validation', str(uuid.uuid4()), 'w1')
                if not close_before_admission:
                    close()
                # Clear setup constraints so rejection cannot be attributed to
                # an unrelated deferred projection check.
                self.c.execute('SET CONSTRAINTS ALL IMMEDIATE')
                self.c.execute('SET CONSTRAINTS ALL DEFERRED')
                before = self.counts()
                with self.assertRaisesRegex(psycopg.Error, 'closed transfer destination'):
                    with self.c.transaction():
                        self.accept(e, 'command', dict(command_id=str(uuid.uuid4()), protocol='external-fence-v1'))
                self.assertEqual(before, self.counts())
                self.assertEqual(self.c.execute("SELECT count(*) FROM api.task_execution_output WHERE execution_id=%s AND port='command'", [e]).fetchone()[0], 0)

    def test_06_intended_use_must_be_nonempty(self):
        source, _ = self.transfer_holdings()
        self.assertEqual(self.call('usability', source, 1, 'transfer')['status'], 'Yes')
        self.assertEqual(self.call('usability', source, 1, 'binding')['status'], 'Unknown')
        # Invalid intended use must be rejected even when eligibility would
        # otherwise return No (insufficient balance) or the holding is absent.
        for holding, quantity in [(source, 1), (source, 11), (str(uuid.uuid4()), 1)]:
            for intended_use in [None, '', '   ']:
                with self.subTest(holding=holding, quantity=quantity, intended_use=intended_use):
                    with self.assertRaisesRegex(psycopg.Error, 'nonempty intended use required'):
                        with self.c.transaction():
                            self.call('usability', holding, quantity, intended_use)

if __name__ == '__main__': unittest.main(verbosity=2)
