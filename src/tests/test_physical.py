"""Physical vertical slice: all setup/effects use authenticated HTTP RPCs.
Only fault-injection trigger installation uses an owner connection.
"""
import concurrent.futures
import pathlib
import sys
import threading
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'scripts'))
from inventory_client import APIError, InventoryClient
from test_modelj import db


class PhysicalInventory(unittest.TestCase):
    def setUp(self):
        self.c = InventoryClient('tenant_b')
        self.loc = {x['workcell']: x['id'] for x in self.c.request('/location')}

    def rejects(self, call, message=None):
        with self.assertRaises(APIError) as result:
            call()
        self.assertGreaterEqual(result.exception.status, 400)
        if message:
            self.assertIn(message, str(result.exception))

    def powder(self, quantity=10):
        con = self.c.container(self.loc['w1'])['container']
        stock = self.c.stock(con)
        self.c.receive(stock['holding'], quantity)
        return stock

    def prep_intent(self, source, destination, quantity=10, output=100):
        return {'source': source, 'destination': destination, 'quantity': quantity, 'unit': 'mg',
                'output_quantity': output, 'output_unit': 'uL', 'method': 'reconstitute@1', 'reason': 'confirmed one-shot preparation'}

    def prepared(self, output=100):
        source = self.powder()
        dest = self.c.container(self.loc['w1'])['container']
        product, run = self.c.prepare(source['holding'], dest, output_quantity=output)
        return source, product, run

    def movement(self, out):
        return self.c.request('/material_movement?output_id=eq.' + out)

    def test_01_registration_receipt_and_exact_preparation_provenance(self):
        source, p, run = self.prepared(200)
        self.assertNotEqual(source['material'], p['material'])
        self.assertEqual(p['identity_decision'], 'Create')
        self.assertEqual(self.c.current(source['holding'])['recorded_quantity'], 0)
        current = self.c.current(p['holding'])
        self.assertEqual((current['recorded_quantity'], current['dimension']), (200, 'volume'))
        self.assertEqual(current['identity']['source_material'], source['material'])
        self.assertEqual(current['identity']['source_holding'], source['holding'])
        self.assertEqual(current['identity']['input_quantity'], 10)
        self.assertEqual((p['input_spec'], p['material_spec']), ('purchased-powder@1', 'reconstituted@1'))
        for out, kind in [(run['input'], 'consumption'), (run['output'], 'production')]:
            m = self.movement(out)
            self.assertEqual(len(m), 1)
            self.assertEqual(m[0]['kind'], kind)
            postings = self.c.request('/material_posting?movement_id=eq.' + m[0]['id'])
            self.assertEqual(sum(x['delta'] for x in postings), 0)
            self.assertEqual(len(postings), 2)
        edges = self.c.request('/task_execution_output_entity?output_id=eq.' + run['output'])
        self.assertTrue(any(x['role']=='source-holding' and x['target_id']==source['holding'] for x in edges))
        self.assertTrue(any(x['role']=='input-acceptance' and x['target_id']==run['input'] for x in edges))
        self.assertTrue(self.c.rpc('verify_balances'))

    def test_02_failed_preparation_retains_consumption_no_fabricated_output(self):
        source = self.powder()
        dest = self.c.container(self.loc['w1'])['container']
        e = self.c.open('reconstitute@1', self.prep_intent(source['holding'], dest))
        cmd = self.c.command(e)
        self.rejects(lambda: self.c.effect(e, 'output', cmd, 100, 'uL'))
        self.c.effect(e, 'input', cmd, 8, 'mg')
        self.c.effect(e, 'unknown', cmd, work='output')
        self.rejects(lambda: self.c.finish(e), 'unresolved mandatory physical work')
        terminal = self.c.finish(e, 'Failed')
        snapshot = self.c.output(terminal)
        self.assertEqual(self.c.current(source['holding'])['recorded_quantity'], 2)
        self.assertEqual(self.c.request('/container_content?container_id=eq.' + dest), [])
        self.assertEqual(self.c.request('/material_movement?output_id=eq.' + terminal), [])
        self.rejects(lambda: self.c.accept(e, 'output', {'command':cmd, 'quantity':100, 'unit':'uL', 'fence_retired':True}), 'evidence')
        late = self.c.effect(e, 'output', cmd, 90, 'uL')
        self.assertEqual(self.c.current(self.c.output(late)['payload']['holding'])['recorded_quantity'], 90)
        self.assertEqual(snapshot, self.c.output(terminal))
        self.assertEqual(self.c.request('/task_execution?id=eq.' + e)[0]['state'], 'Failed')

    def test_03_insufficient_units_and_unsupported_transformation(self):
        source = self.powder()
        dest = self.c.container(self.loc['w1'])['container']
        i = self.prep_intent(source['holding'], dest)
        self.rejects(lambda: self.c.open('reconstitute@1', {**i,'method':'arbitrary-pooling@1'}), 'unsupported transformation')
        self.rejects(lambda: self.c.open('reconstitute@2', i), 'unsupported inventory handler')
        self.rejects(lambda: self.c.open('reconstitute@1', {**i,'unit':'uL'}), 'unit/dimension')
        e = self.c.open('reconstitute@1', {**i, 'quantity':11})
        self.rejects(lambda: self.c.command(e), 'not currently usable')
        e = self.c.open('reconstitute@1', i)
        cmd = self.c.command(e)
        self.rejects(lambda: self.c.effect(e,'input',cmd,1,'uL'), 'unit/dimension')
        self.rejects(lambda: self.c.effect(e,'input',cmd,11,'mg'), 'exceeds command')
        self.c.effect(e,'input',cmd,.01,'g')
        self.rejects(lambda: self.c.effect(e,'output',cmd,101,'uL'), 'exceeds confirmed command')
        out = self.c.effect(e,'output',cmd,.1,'mL')
        self.assertEqual(self.c.current(self.c.output(out)['payload']['holding'])['recorded_quantity'], 100)

    def test_04_idempotency_and_duplicate_business_work(self):
        source = self.powder()
        dest = self.c.container(self.loc['w1'])['container']
        intent = self.prep_intent(source['holding'], dest)
        key = self.c.key()
        e = self.c.open('reconstitute@1', intent, key=key)
        self.assertEqual(e, self.c.open('reconstitute@1',intent,key=key))
        self.rejects(lambda: self.c.open('reconstitute@1',{**intent,'quantity':9},key=key), 'conflicting')
        cmd = self.c.command(e)
        command_record = self.c.output(cmd)
        self.assertEqual(cmd,self.c.accept(e,'command',command_record['request']['payload'],key=command_record['request_key']))
        first = self.c.effect(e,'input',cmd,10,'mg',key='input')
        self.assertEqual(first,self.c.effect(e,'input',cmd,10,'mg',key='input'))
        self.rejects(lambda: self.c.effect(e,'input',cmd,9,'mg',key='input'), 'conflicting')
        self.rejects(lambda: self.c.effect(e,'input',cmd,10,'mg'), 'already settled')
        out = self.c.effect(e,'output',cmd,100,'uL',key='output')
        self.c.finish(e)
        self.assertEqual(out,self.c.effect(e,'output',cmd,100,'uL',key='output'))
        self.assertEqual(len(self.movement(out)), 1)
        self.rejects(lambda: self.c.effect(e,'output',cmd,100,'uL'), 'already settled')

    def test_05_plate_relocation_preserves_wells_and_quantity(self):
        _, p, _ = self.prepared(200)
        plate = self.c.container(self.loc['w1'], 'plate384@1')
        wells_before = self.c.request('/container?parent_id=eq.' + plate['container'] + '&order=position')
        self.assertEqual(len(wells_before),384)
        holding = self.c.holding(p['material'],wells_before[0]['id'])
        self.assertEqual(holding['identity_decision'],'Reuse')
        transfer = self.c.aliquot(p['holding'],holding['holding'],80)
        before = self.c.current(holding['holding'])
        e = self.c.open('relocate@1', {'container':plate['container'], 'location':self.loc['w2'], 'position':self.c.key()[-20:], 'expected_seq':0})
        out = self.c.effect(e,'move',self.c.command(e))
        self.c.finish(e)
        after = self.c.current(holding['holding'])
        self.assertEqual((before['workcell'],after['workcell']),('w1','w2'))
        self.assertEqual((before['recorded_quantity'],after['recorded_quantity']),(80,80))
        self.assertEqual(after['material_id'],p['material'])
        self.assertEqual(wells_before,self.c.request('/container?parent_id=eq.' + plate['container'] + '&order=position'))
        self.assertEqual(after['placement_chain'][-1]['placement_output'],out)
        self.assertEqual(self.movement(out),[])
        history = self.c.output(out)['payload']
        self.assertEqual(history['before']['location'],self.loc['w1'])
        self.assertEqual(history['after']['location'],self.loc['w2'])
        self.assertEqual(history['after']['seq'],1)
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],120)
        self.rejects(lambda:self.c.open('relocate@1',{'container':wells_before[0]['id'],'location':self.loc['w2'],'position':'bad','expected_seq':0},'w2'),'fixed well')

    def test_06_parent_ancestry_compatibility_and_occupancy(self):
        a = self.c.container(self.loc['w1'],'rack@1')['container']
        b = self.c.container(None,'rack@1',parent=a,position='S01')['container']
        tube = self.c.container(self.loc['w1'])['container']
        self.rejects(lambda:self.c.open('relocate@1',{'container':a,'parent':b,'position':'S01','expected_seq':0}), 'ancestry cycle')
        self.rejects(lambda:self.c.container(None,parent=a,position='S01'), 'occupied')
        self.rejects(lambda:self.c.container(None,parent=a,position='S25'), 'incompatible')
        self.rejects(lambda:self.c.container(None,parent=tube,position='S01'), 'incompatible')
        target = self.c.container(self.loc['w1'],position='occupied-'+self.c.key()[-12:])
        occupied_pos = target['intent']['position']
        self.rejects(lambda:self.c.open('relocate@1',{'container':tube,'location':self.loc['w1'],'position':occupied_pos,'expected_seq':0}), 'occupied')
        e = self.c.open('relocate@1',{'container':tube,'parent':b,'position':'S02','expected_seq':0})
        out = self.c.effect(e,'move',self.c.command(e))
        self.assertEqual(self.c.request('/container?id=eq.'+tube)[0]['parent_id'],b)
        self.assertEqual(self.movement(out),[])
        self.rejects(lambda:self.c.open('relocate@1',{'container':tube,'parent':a,'position':'S02','expected_seq':0}), 'predecessor')

    def test_07_unknown_relocation_blocks_source_and_slot(self):
        _, p, _ = self.prepared()
        con = self.c.current(p['holding'])['container_id']
        pos = self.c.key()[-20:]
        e = self.c.open('relocate@1',{'container':con,'location':self.loc['w2'],'position':pos,'expected_seq':0})
        cmd = self.c.command(e)
        unknown = self.c.effect(e,'unknown',cmd,work='move')
        self.assertEqual(self.movement(unknown),[])
        self.assertEqual(self.c.current(p['holding'])['workcell'],'w1')
        self.assertTrue(self.c.current(p['holding'])['pending_physical_scope'])
        self.rejects(lambda:self.c.withdraw(p['holding'],1), 'unresolved physical')
        self.rejects(lambda:self.c.container(self.loc['w2'],position=pos,wc='w2'), 'pending placement')
        self.rejects(lambda:self.c.finish(e), 'unresolved mandatory')
        terminal = self.c.finish(e,'Failed')
        snapshot = self.c.output(terminal)
        self.c.effect(e,'move',cmd)
        self.assertEqual(self.c.current(p['holding'])['workcell'],'w2')
        self.assertFalse(self.c.current(p['holding'])['pending_physical_scope'])
        self.assertEqual(snapshot,self.c.output(terminal))

    def test_08_consumption_disposal_exact_balances_and_closure(self):
        _, p, _ = self.prepared(100)
        self.rejects(lambda:self.c.close(p['holding']), 'zero quantity')
        consume = self.c.withdraw(p['holding'],.025,unit='mL')
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],75)
        dispose = self.c.withdraw(p['holding'],75,'dispose')
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],0)
        for out,account in [(consume,'consumption'),(dispose,'disposal')]:
            movement = self.movement(out)[0]
            postings = self.c.request('/material_posting?movement_id=eq.'+movement['id'])
            self.assertTrue(any(x['account']==account and x['delta']>0 for x in postings))
            self.assertEqual(sum(x['delta'] for x in postings),0)
            root = self.c.output(out)
            self.assertEqual(root['actor'],'tenant_b')
            self.assertTrue(root['payload']['intent']['reason'])
        self.c.close(p['holding'])
        self.assertTrue(self.c.current(p['holding'])['closed'])
        self.rejects(lambda:self.c.withdraw(p['holding'],1))
        self.assertTrue(self.c.rpc('verify_balances'))

    def test_09_concurrent_withdrawals_cannot_overspend(self):
        _, p, _ = self.prepared(100)
        i = {'source':p['holding'],'quantity':70,'unit':'uL','reason':'assay'}
        es = [self.c.open('consume@1',i),self.c.open('dispose@1',i)]
        barrier = threading.Barrier(2)
        def run(e):
            barrier.wait()
            try: return self.c.command(e)
            except APIError: return None
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(run,es))
        self.assertEqual(sum(x is not None for x in results),1)
        winner = 0 if results[0] else 1
        self.c.effect(es[winner],['consume','dispose'][winner],results[winner],70,'uL')
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],30)
        self.rejects(lambda:self.c.command(es[1-winner]))

    def test_10_unknown_use_never_posts_or_clears_scope(self):
        _, p, _ = self.prepared(100)
        e = self.c.open('consume@1',{'source':p['holding'],'quantity':40,'unit':'uL','reason':'assay'})
        cmd = self.c.command(e)
        out = self.c.effect(e,'unknown',cmd,work='use')
        self.assertEqual(self.movement(out),[])
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],100)
        self.rejects(lambda:self.c.withdraw(p['holding'],1,'dispose'), 'unresolved physical')
        terminal = self.c.finish(e,'Canceled')
        old = self.c.output(terminal)
        self.c.effect(e,'consume',cmd,35,'uL')
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],65)
        self.assertEqual(old,self.c.output(terminal))

    def test_11_concurrent_duplicate_effect_is_once_only(self):
        _, p, _ = self.prepared(100)
        e = self.c.open('consume@1',{'source':p['holding'],'quantity':40,'unit':'uL','reason':'assay'})
        cmd = self.c.command(e)
        self.rejects(lambda:self.c.effect(e,'consume',cmd,40,'uL',outcome='unknown'), 'explicit physical outcome')
        self.rejects(lambda:self.c.effect(e,'consume',cmd,40,'uL',confirmed=False), 'independent confirmation')
        self.rejects(lambda:self.c.effect(e,'consume',cmd,40,'uL',fence_retired=False), 'command retirement')
        barrier = threading.Barrier(2)
        def run(_):
            barrier.wait()
            return self.c.effect(e,'consume',cmd,40,'uL',key='same-confirmed-effect')
        with concurrent.futures.ThreadPoolExecutor(2) as pool: results = list(pool.map(run,range(2)))
        self.assertEqual(results[0],results[1])
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],60)
        self.assertEqual(len(self.movement(results[0])),1)
        self.rejects(lambda:self.c.effect(e,'consume',cmd,39,'uL',key='same-confirmed-effect'), 'conflicting')
        self.rejects(lambda:self.c.effect(e,'consume',cmd,40,'uL'), 'already settled')

    def test_12_tenant_site_workcell_boundaries(self):
        _, p, run = self.prepared()
        a = InventoryClient('tenant_a')
        self.assertEqual(a.request('/material?id=eq.'+p['material']),[])
        self.assertEqual(a.request('/task_execution_output?id=eq.'+p['input_output']),[])
        with self.assertRaises(APIError): a.rpc('current_inventory',holding=p['holding'])
        with self.assertRaises(APIError): a.effect(run['execution'],'output',run['command'],1,'uL')
        with self.assertRaises(APIError): a.open('consume@1',{'source':p['holding'],'quantity':1,'unit':'uL','reason':'attempt'})
        con = self.c.current(p['holding'])['container_id']
        self.rejects(lambda:self.c.open('consume@1',{'source':p['holding'],'quantity':1,'unit':'uL','reason':'wrong cell'},'w2'),'wrong physical workcell')
        self.rejects(lambda:self.c.open('relocate@1',{'container':con,'location':self.loc['w3'],'position':'remote','expected_seq':0}),'cross sites')
        a_loc = a.request('/location?workcell=eq.w1')[0]['id']
        self.rejects(lambda:self.c.container(a_loc))
        with self.assertRaises(APIError): a.holding(p['material'],a.container(a_loc)['container'])

    def test_13_preparation_projection_failure_rolls_back(self):
        source = self.powder()
        dest = self.c.container(self.loc['w1'])['container']
        e = self.c.open('reconstitute@1',self.prep_intent(source['holding'],dest))
        cmd = self.c.command(e)
        self.c.effect(e,'input',cmd,10,'mg')
        for table,event in [('material','INSERT'),('container_content','INSERT'),('material_posting','INSERT'),('material_balance','UPDATE')]:
            with db(None) as c:
                c.execute("CREATE OR REPLACE FUNCTION api.physical_test_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'physical fault'; END $$")
                c.execute(f'CREATE TRIGGER physical_test_fault AFTER {event} ON api.{table} FOR EACH ROW EXECUTE FUNCTION api.physical_test_fault()')
            try:
                before = self.c.request('/task_execution_output?execution_id=eq.'+e)
                self.rejects(lambda:self.c.effect(e,'output',cmd,100,'uL',key='production'), 'physical fault')
                self.assertEqual(before,self.c.request('/task_execution_output?execution_id=eq.'+e))
                self.assertEqual(self.c.request('/container_content?container_id=eq.'+dest),[])
            finally:
                with db(None) as c: c.execute(f'DROP TRIGGER physical_test_fault ON api.{table}')
        output = self.c.effect(e,'output',cmd,100,'uL',key='production')
        self.assertEqual(self.c.current(self.c.output(output)['payload']['holding'])['recorded_quantity'],100)
        self.assertTrue(self.c.rpc('verify_balances'))

    def test_14_relocation_failure_rolls_back_current_and_history(self):
        _, p, _ = self.prepared()
        con = self.c.current(p['holding'])['container_id']
        e = self.c.open('relocate@1',{'container':con,'location':self.loc['w2'],'position':self.c.key()[-20:],'expected_seq':0})
        cmd = self.c.command(e)
        with db(None) as c:
            c.execute("CREATE OR REPLACE FUNCTION api.physical_test_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'physical fault'; END $$")
            c.execute('CREATE TRIGGER physical_test_fault AFTER UPDATE ON api.container FOR EACH ROW EXECUTE FUNCTION api.physical_test_fault()')
        try:
            self.rejects(lambda:self.c.effect(e,'move',cmd), 'physical fault')
            self.assertEqual(self.c.current(p['holding'])['workcell'],'w1')
            self.assertEqual(self.c.request('/container?id=eq.'+con)[0]['placement_seq'],0)
            self.assertEqual(self.c.request('/task_execution_output?execution_id=eq.'+e+'&port=eq.settlement'),[])
        finally:
            with db(None) as c: c.execute('DROP TRIGGER physical_test_fault ON api.container')
        self.c.effect(e,'move',cmd)
        self.assertEqual(self.c.current(p['holding'])['workcell'],'w2')

    def test_15_unknown_preparation_blocks_receipt_and_empty_destination(self):
        source = self.powder()
        dest = self.c.container(self.loc['w1'])['container']
        e = self.c.open('reconstitute@1',self.prep_intent(source['holding'],dest))
        cmd = self.c.command(e)
        self.c.effect(e,'unknown',cmd,work='input')
        self.rejects(lambda:self.c.receive(source['holding'],1), 'unresolved physical')
        self.rejects(lambda:self.c.stock(dest), 'unresolved physical')
        self.assertEqual(self.c.current(source['holding'])['recorded_quantity'],10)
        self.c.effect(e,'zero',cmd,0,work='input')
        self.c.effect(e,'zero',cmd,0,work='output')
        self.rejects(lambda:self.c.finish(e), 'confirmed preparation output missing')
        self.c.finish(e,'Failed')
        self.assertEqual(self.c.request('/container_content?container_id=eq.'+dest),[])

    def test_16_current_restriction_blocks_consumption_not_safe_disposal(self):
        _, p, _ = self.prepared()
        e = self.c.open('consume@1',{'source':p['holding'],'quantity':20,'unit':'uL','reason':'planned assay'})
        task = self.c.rpc('create_task',spec='correction@1',request_key=self.c.key(),intent={})
        review = self.c.rpc('start_execution',task=task,workcell='w1')
        self.c.rpc('accept',execution=review,request_key=self.c.key(),port='correction',payload={'type':'restrict','holding':p['holding']})
        self.rejects(lambda:self.c.command(e), 'not currently usable')
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],100)
        # Restricted stock may be removed as waste, not used in an assay.
        self.c.withdraw(p['holding'],100,'dispose')
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],0)

    def test_17_confirmed_zero_is_not_successful_consumption(self):
        _, p, _ = self.prepared()
        e = self.c.open('consume@1',{'source':p['holding'],'quantity':20,'unit':'uL','reason':'assay'})
        cmd = self.c.command(e)
        out = self.c.effect(e,'zero',cmd,0,work='use')
        self.assertEqual(self.movement(out),[])
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],100)
        self.rejects(lambda:self.c.finish(e), 'confirmed withdrawal missing')
        self.c.finish(e,'Failed')
        # Positively retired zero scope permits a distinct newly authorized operation.
        self.c.withdraw(p['holding'],20)
        self.assertEqual(self.c.current(p['holding'])['recorded_quantity'],80)


if __name__=='__main__': unittest.main(verbosity=2)
