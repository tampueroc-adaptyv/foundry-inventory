"""Real PostgreSQL and PostgREST tests. Run after scripts/reset.sh."""
import base64
import concurrent.futures
from contextlib import contextmanager
import hashlib
import hmac
import json
import os
import threading
import time
import unittest
import urllib.request
import urllib.error
import uuid

import psycopg
from psycopg.types.json import Jsonb

DSN = os.getenv('DATABASE_URL', 'postgresql://postgres:modelj@localhost:55432/modelj')
API = os.getenv('API_URL', 'http://localhost:53000')


def fid(s):
    return uuid.UUID(hashlib.md5(s.encode()).hexdigest())


@contextmanager
def db(role='tenant_a'):
    c = psycopg.connect(DSN)
    try:
        with c:
            if role:
                c.execute('SET ROLE ' + role)  # fixed test constants only
            yield c
    finally:
        c.close()


def sql(query, args=(), role='tenant_a'):
    with db(role) as c:
        return c.execute(query, args).fetchone()[0]


def rpc(name, **kw):
    vals = [Jsonb(v) if isinstance(v, (dict, list)) else v for v in kw.values()]
    return sql('SELECT api.' + name + '(' + ','.join(k + '=>%s' for k in kw) + ')', vals)


def token(role='tenant_a', **extra):
    enc = lambda x: base64.urlsafe_b64encode(json.dumps(x, separators=(',', ':')).encode()).rstrip(b'=')
    msg = enc({'alg': 'HS256', 'typ': 'JWT'}) + b'.' + enc({'role': role, 'exp': int(time.time()) + 3600, **extra})
    sig = base64.urlsafe_b64encode(hmac.new(b'modelj-local-test-secret-at-least-32-characters', msg, hashlib.sha256).digest()).rstrip(b'=')
    return (msg + b'.' + sig).decode()


def http(path, data=None, role='tenant_a', method=None, **claims):
    req = urllib.request.Request(API + path, data=None if data is None else json.dumps(data).encode(),
                                 headers={'Authorization': 'Bearer ' + token(role, **claims), 'Content-Type': 'application/json'}, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        with e:
            return e.code, json.loads(e.read())


class ModelJ(unittest.TestCase):
    n = 0

    @classmethod
    def key(cls, prefix='test'):
        cls.n += 1
        return f'{prefix}-{cls.n}'

    def task(self, spec, intent=None, workcell='w1'):
        t = rpc('create_task', spec=spec, request_key=self.key(), intent=intent or {})
        return t, rpc('start_execution', task=t, workcell=workcell)

    def accept(self, e, port, payload, key=None):
        return rpc('accept', execution=e, request_key=key or self.key(), port=port, payload=payload)

    def receipt(self, h, qty=100, key=None):
        intent = dict(supplier='supplier-verified', delivery=key or self.key('delivery'), line='1', lot='L1',
                      coa={'version': 'coa-v1', 'sha256': 'a' * 64}, holding=str(fid('aholding' + str(h))), quantity=qty, unit='uL')
        out = rpc('register_receipt', request_key=self.key(), intent=intent, workcell='w1', evidence='signed delivery scan')
        return out, intent

    def transfer(self, src, dst, qty=20):
        return self.task('transfer@1', {'items': [{'key': 'well-1', 'source': str(fid('aholding' + str(src))),
                                                   'destination': str(fid('aholding' + str(dst))), 'quantity': qty, 'unit': 'uL'}]})

    def command(self, e):
        return self.accept(e, 'command', {'command_id': self.key('robot'), 'protocol': 'external-fence-v1'})

    def settle(self, e, cmd, outcome, qty=None, key=None):
        p = {'command': str(cmd), 'key': 'well-1', 'outcome': outcome, 'evidence': 'signed robot evidence', 'fence_retired': True}
        if qty is not None:
            p['quantity'] = qty
        return self.accept(e, 'settlement', p, key)

    def balance(self, h):
        return sql('SELECT amount FROM api.material_balance WHERE holding_id=%s', [fid('aholding' + str(h))])

    def rejects(self, fn):
        with self.assertRaises(psycopg.Error):
            fn()

    def test_A01_schema_19_and_foreign_keys(self):
        self.assertEqual(sql("SELECT count(*) FROM information_schema.tables WHERE table_schema='api' AND table_type='BASE TABLE'", role=None), 19)
        self.rejects(lambda: sql("INSERT INTO api.container_content(tenant_id,material_id,container_id,dimension) VALUES('a',%s,%s,'volume') RETURNING id", [uuid.uuid4(), fid('awell1')], role=None))

    def test_A02_active_holding_and_fixed_well_uniqueness(self):
        self.rejects(lambda: sql("INSERT INTO api.container_content(tenant_id,material_id,container_id,dimension) VALUES('a',%s,%s,'volume') RETURNING id", [fid('aprotein'), fid('awell1')], role=None))
        self.rejects(lambda: sql("INSERT INTO api.container(tenant_id,spec_id,parent_id,position,fixed) VALUES('a','well@1',%s,'A01',true) RETURNING id", [fid('aplate')], role=None))

    def test_A03_catalog_immutable(self):
        for table in ('material_spec_catalog', 'container_spec_catalog', 'location_spec_catalog', 'task_spec_catalog', 'observation_specification_catalog', 'assessment_specification_catalog'):
            self.rejects(lambda: sql(f"UPDATE api.{table} SET definition='{{}}' RETURNING id", role=None))

    def test_A04_direct_writes_denied(self):
        for table in ('material_balance', 'material_posting', 'task_execution_output', 'assessment', 'task', 'container_content'):
            self.rejects(lambda: sql(f'DELETE FROM api.{table} RETURNING 1'))
        self.rejects(lambda: sql("SELECT api.post('a',%s,NULL,'receipt',1,'uL')", [uuid.uuid4()]))

    def test_B01_receipt_balance_idempotency_external_dedup(self):
        o, intent = self.receipt(1)
        self.assertEqual(self.balance(1), 100)
        self.assertEqual(rpc('register_receipt', request_key=self.key(), intent=intent, workcell='w1', evidence='retry scan'), o)
        self.assertEqual(self.balance(1), 100)
        self.rejects(lambda: rpc('register_receipt', request_key=self.key(), intent={**intent, 'quantity': 101}, workcell='w1', evidence='scan'))

    def test_B02_posting_and_output_immutable(self):
        o, _ = self.receipt(2)
        for table, where in [('task_execution_output', 'id'), ('material_posting', 'movement_id')]:
            ident = o if where == 'id' else sql('SELECT id FROM api.material_movement WHERE output_id=%s', [o])
            self.rejects(lambda: sql(f'DELETE FROM api.{table} WHERE {where}=%s RETURNING 1', [ident], role=None))

    def test_B03_balanced_constraint_and_wrong_dimension(self):
        o, _ = self.receipt(3)
        def unbalanced():
            with db(None) as c:
                m = c.execute("INSERT INTO api.material_movement(tenant_id,output_id,member,material_id,dimension,kind) VALUES('a',%s,'invalid',%s,'volume','receipt') RETURNING id", [o, fid('aprotein')]).fetchone()[0]
                c.execute("INSERT INTO api.material_posting(tenant_id,movement_id,material_id,dimension,account,entered,unit,delta) VALUES('a',%s,%s,'volume','receipt',1,'uL',1)", [m, fid('aprotein')])
        self.rejects(unbalanced)
        self.rejects(lambda: sql("SELECT api.normalized(1,'mg','volume')", role=None))
        self.rejects(lambda: sql("SELECT api.normalized(0.0000001,'uL','volume')", role=None))

    def test_B04_negative_and_conflicting_settlement_retry(self):
        self.receipt(4, 10)
        _, e = self.transfer(4, 5, 20)
        self.rejects(lambda: self.command(e))
        _, e = self.transfer(4, 5, 10)
        cmd = self.command(e)
        o = self.settle(e, cmd, 'full', 10, 'stable')
        self.assertEqual(o, self.settle(e, cmd, 'full', 10, 'stable'))
        self.rejects(lambda: self.settle(e, cmd, 'partial', 9, 'stable'))
        self.rejects(lambda: self.settle(e, cmd, 'full', 10))
        self.assertEqual(self.balance(4), 0)
        self.assertEqual(self.balance(5), 10)

    def test_B05_parallel_command_scope_prevents_overspend(self):
        self.receipt(6, 100)
        _, e1 = self.transfer(6, 7, 70)
        _, e2 = self.transfer(6, 8, 70)
        barrier = threading.Barrier(2)
        def run(e):
            barrier.wait()
            try:
                return self.command(e)
            except psycopg.Error:
                return None
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            result = list(pool.map(run, (e1, e2)))
        self.assertEqual(sum(x is not None for x in result), 1)
        winner = 0 if result[0] else 1
        self.settle((e1, e2)[winner], result[winner], 'full', 70)
        self.assertEqual(self.balance(6), 30)

    def test_B06_rebuild_matches_projection(self):
        self.assertTrue(rpc('verify_balances'))

    def test_B07_replace_preserves_subsequent_activity(self):
        self.receipt(9, 100)
        _, e = self.transfer(9, 10, 20)
        cmd = self.command(e)
        o = self.settle(e, cmd, 'full', 20)
        _, e2 = self.transfer(10, 11, 10)
        self.settle(e2, self.command(e2), 'full', 10)
        orig = sql('SELECT id FROM api.material_movement WHERE output_id=%s', [o])
        _, corr = self.task('correction@1')
        payload = {'type': 'replace', 'original': str(orig), 'quantity': 15, 'unit': 'uL', 'reason': 'original claim overstated by 5'}
        self.accept(corr, 'correction', payload)
        self.assertEqual((self.balance(9), self.balance(10), self.balance(11)), (85, 5, 10))
        self.rejects(lambda: self.accept(corr, 'correction', payload))
        self.assertTrue(rpc('verify_balances'))

    def test_B08_reconciliation_independent_count(self):
        self.receipt(12, 50)
        _, e = self.task('correction@1')
        p = dict(type='reconcile', holding=str(fid('aholding12')), expected_seq=1, observed=45, custody='confirmed', count_id='count-12', evidence='balance certificate')
        self.accept(e, 'correction', p)
        self.assertEqual(self.balance(12), 45)
        self.rejects(lambda: self.accept(e, 'correction', {**p, 'expected_seq': 2}))
        self.rejects(lambda: self.accept(e, 'correction', {**p, 'count_id': 'new-count'}))

    def test_B09_negative_replacement_rolls_back_atomically(self):
        self.receipt(32, 100)
        _, e = self.transfer(32, 33, 20)
        o = self.settle(e, self.command(e), 'full', 20)
        _, later = self.transfer(33, 34, 15)
        self.settle(later, self.command(later), 'full', 15)
        orig = sql('SELECT id FROM api.material_movement WHERE output_id=%s', [o])
        _, corr = self.task('correction@1')
        before = sql('SELECT count(*) FROM api.material_movement')
        self.rejects(lambda: self.accept(corr, 'correction', {'type': 'replace', 'original': str(orig), 'quantity': 10, 'unit': 'uL', 'reason': 'would overdraw after subsequent transfer'}))
        self.assertEqual(sql('SELECT count(*) FROM api.material_movement'), before)
        self.assertEqual((self.balance(32), self.balance(33), self.balance(34)), (80, 5, 15))

    def test_B10_exact_unit_normalization(self):
        o, intent = self.receipt(31, 1)
        modified = {**intent, 'delivery': self.key(), 'quantity': 0.125, 'unit': 'mL'}
        rpc('register_receipt', request_key=self.key(), intent=modified, workcell='w1', evidence='verified')
        self.assertEqual(self.balance(31), 126)
        self.assertTrue(rpc('verify_balances'))

    def test_B11_shared_source_aggregate_authorization(self):
        self.receipt(35, 100)
        items = [{'key': str(i), 'source': str(fid('aholding35')), 'destination': str(fid('aholding'+str(36+i))), 'quantity': 50, 'unit': 'uL'} for i in range(3)]
        _, e = self.task('transfer@1', {'items': items})
        self.rejects(lambda: self.command(e))
        self.assertEqual(self.balance(35), 100)

    def test_B12_full_balance_rebuild(self):
        with db() as c:
            before = c.execute('SELECT holding_id,amount FROM api.material_balance ORDER BY holding_id').fetchall()
        self.assertEqual(rpc('rebuild_balances'), 386)
        with db() as c:
            after = c.execute('SELECT holding_id,amount FROM api.material_balance ORDER BY holding_id').fetchall()
        self.assertEqual(before, after)
        self.assertTrue(rpc('verify_balances'))

    def test_C01_partial_zero_unknown_late_resolution_terminal_snapshot(self):
        self.receipt(13, 100)
        _, e = self.transfer(13, 14, 20)
        cmd = self.command(e)
        self.settle(e, cmd, 'unknown')
        self.assertEqual(self.balance(13), 100)
        terminal = self.accept(e, 'terminal', {'state': 'Failed', 'reason': 'instrument timeout'}, 'terminate')
        snapshot = sql('SELECT payload FROM api.task_execution_output WHERE id=%s', [terminal])
        _, next_e = self.transfer(13, 15, 5)
        self.rejects(lambda: self.command(next_e))
        self.settle(e, cmd, 'partial', 12)
        self.assertEqual((self.balance(13), self.balance(14)), (88, 12))
        self.assertEqual(snapshot, sql('SELECT payload FROM api.task_execution_output WHERE id=%s', [terminal]))
        self.assertEqual(sql('SELECT state FROM api.task_execution WHERE id=%s', [e]), 'Failed')
        self.rejects(lambda: self.settle(e, cmd, 'partial', 12))
        _, z = self.transfer(13, 16, 5)
        cmd2 = self.command(z)
        out = self.settle(z, cmd2, 'zero', 0)
        self.assertEqual(sql('SELECT count(*) FROM api.material_movement WHERE output_id=%s', [out]), 0)

    def test_C02_independent_per_well_outcomes(self):
        self.receipt(40, 100)
        items = [{'key': str(i), 'source': str(fid('aholding40')), 'destination': str(fid('aholding'+str(41+i))), 'quantity': 5, 'unit': 'uL'} for i in range(4)]
        _, e = self.task('transfer@1', {'items': items})
        cmd = self.command(e)
        for i, outcome, q in [(0, 'full', 5), (1, 'partial', 2), (2, 'zero', 0), (3, 'unknown', None)]:
            p = {'command': str(cmd), 'key': str(i), 'outcome': outcome, 'evidence': 'per-well report', 'fence_retired': True}
            if q is not None:
                p['quantity'] = q
            self.accept(e, 'settlement', p)
        self.assertEqual(self.balance(40), 93)
        terminal = self.accept(e, 'terminal', {'state': 'Failed', 'reason': 'one unresolved well'})
        self.assertEqual(sql('SELECT payload->\'unresolved\' FROM api.task_execution_output WHERE id=%s', [terminal]), ['3'])
        self.accept(e, 'settlement', {'command': str(cmd), 'key': '3', 'outcome': 'partial', 'quantity': 3, 'evidence': 'late confirmed log', 'fence_retired': True})
        self.assertEqual([self.balance(i) for i in range(40, 45)], [90, 5, 2, 0, 3])

    def test_C03_zero_requires_external_command_retirement(self):
        self.receipt(45, 10)
        _, e = self.transfer(45, 46, 5)
        cmd = self.command(e)
        self.rejects(lambda: self.accept(e, 'settlement', {'command': str(cmd), 'key': 'well-1', 'outcome': 'zero', 'quantity': 0, 'evidence': 'no fence confirmation'}))
        self.assertEqual(rpc('usability', holding=fid('aholding45'), quantity=1, intended_use='transfer')['status'], 'Unknown')
        self.settle(e, cmd, 'zero', 0)

    def test_C04_closure_requires_zero_and_resolved_scope(self):
        self.receipt(49, 10)
        _, e = self.transfer(49, 50, 5)
        cmd = self.command(e)
        _, corr = self.task('correction@1')
        self.rejects(lambda: self.accept(corr, 'correction', {'type': 'close_holding', 'holding': str(fid('aholding49'))}))
        self.rejects(lambda: self.accept(corr, 'correction', {'type': 'close_holding', 'holding': str(fid('aholding50'))}))
        self.settle(e, cmd, 'zero', 0)
        self.accept(corr, 'correction', {'type': 'close_holding', 'holding': str(fid('aholding50'))})
        self.assertTrue(sql('SELECT closed FROM api.container_content WHERE id=%s', [fid('aholding50')]))
        self.rejects(lambda: self.receipt(50, 1))

    def test_D01_mandatory_receipt_observation_checkpoint(self):
        _, intent = self.receipt(17)
        # A distinct line and holding creates an unconfirmed receipt task.
        t, e = self.task('receipt@1', {**intent, 'delivery': self.key()})
        self.rejects(lambda: self.accept(e, 'terminal', {'state': 'Completed', 'reason': 'claim'}))
        self.receipt(18)
        _, e = self.transfer(18, 19, 5)
        self.settle(e, self.command(e), 'full', 5)
        self.rejects(lambda: self.accept(e, 'terminal', {'state': 'Completed', 'reason': 'missing checkpoint'}))
        self.accept(e, 'checkpoint', {'name': 'verified', 'evidence': 'operator signed'})
        self.accept(e, 'terminal', {'state': 'Completed', 'reason': 'all accepted'})
        self.assertEqual(sql('SELECT state FROM api.task WHERE id=(SELECT task_id FROM api.task_execution WHERE id=%s)', [e]), 'Pending')

    def test_D02_concurrent_terminal_claim_once_and_retry(self):
        _, e = self.task('correction@1')
        barrier = threading.Barrier(2)
        def run(state):
            barrier.wait()
            try:
                return self.accept(e, 'terminal', {'state': state, 'reason': 'stop'}, state)
            except psycopg.Error:
                return None
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            result = list(pool.map(run, ['Failed', 'Canceled']))
        self.assertEqual(sum(x is not None for x in result), 1)
        winner = 'Failed' if result[0] else 'Canceled'
        self.assertEqual(self.accept(e, 'terminal', {'state': winner, 'reason': 'stop'}, winner), result[0] or result[1])

    def acquisition(self):
        mapping = [dict(member=chr(65 + (i-1)//24) + f'{(i-1)%24+1:02}', holding=str(fid('aholding'+str(i))),
                        well=str(fid('awell'+str(i))), protein=str(fid('aprotein')), target=str(fid('atarget')), basis=str(fid('aqc'+str(i)))) for i in range(1, 385)]
        t, e = self.task('acquisition@1', {'plate': str(fid('aplate')), 'mapping': mapping})
        p = {'mapping': mapping, 'artifact': {'bucket': 'mock-s3', 'key': self.key('run'), 'version': 'v1', 'sha256': 'a'*64, 'size': 12345, 'format': 'binding-curves@1'}}
        return t, e, p

    def test_E01_shared384_pairing_processing_reinterpretation(self):
        t, e, p = self.acquisition()
        self.rejects(lambda: self.accept(e, 'terminal', {'state': 'Completed', 'reason': 'missing observation'}))
        bad = {**p, 'mapping': p['mapping'][:-1]}
        self.rejects(lambda: self.accept(e, 'acquisition', bad))
        out = self.accept(e, 'acquisition', p)
        obs = sql('SELECT id FROM api.observation WHERE output_id=%s', [out])
        self.assertEqual(sql('SELECT count(*) FROM api.observation WHERE output_id=%s', [out]), 1)
        self.assertEqual(sql('SELECT count(*) FROM api.task_execution_output_entity WHERE output_id=%s', [out]), 384*5)
        self.accept(e, 'terminal', {'state': 'Completed', 'reason': 'dataset accepted'})
        _, fit = self.task('processing@3', {'observation': str(obs)})
        results = [dict(member=x['member'], subject={k:v for k,v in x.items() if k!='basis'}, outcome='binding', dependencies=[x['basis']]) for x in p['mapping']]
        self.rejects(lambda: self.accept(fit, 'interpretation', {'results': results[:-1]}))
        bad = json.loads(json.dumps(results)); bad[0]['subject']['target'] = str(fid('aprotein'))
        self.rejects(lambda: self.accept(fit, 'interpretation', {'results': bad}))
        bad = json.loads(json.dumps(results)); bad[0]['dependencies'] = []
        self.rejects(lambda: self.accept(fit, 'interpretation', {'results': bad}))
        o = self.accept(fit, 'interpretation', {'results': results})
        self.assertEqual(sql('SELECT count(*) FROM api.assessment WHERE output_id=%s', [o]), 384)
        _, fit4 = self.task('processing@4', {'observation': str(obs)})
        o4 = self.accept(fit4, 'interpretation', {'results': results})
        self.assertEqual(sql('SELECT count(*) FROM api.assessment WHERE output_id=%s AND spec_id=%s', [o4, 'binding-fit@4']), 384)
        # Scoped pair interpretation alone is not Task authority.
        pair = sql('SELECT id FROM api.assessment WHERE output_id=%s LIMIT 1', [o])
        _, review = self.task('review@1', {'observation': str(obs), 'member': 'A01', 'subject': str(t), 'subject_type': 'task'})
        self.rejects(lambda: self.accept(review, 'transition', {'target': str(t), 'assessment': str(pair), 'expected_seq': 0}))
        ro = self.accept(review, 'review', {'observation': str(obs), 'member': 'A01', 'subject': str(t), 'subject_type': 'task', 'outcome': 'pass'})
        a = sql('SELECT id FROM api.assessment WHERE output_id=%s', [ro])
        tr = self.accept(review, 'transition', {'target': str(t), 'assessment': str(a), 'expected_seq': 0}, 'control')
        self.assertEqual(sql('SELECT state FROM api.task WHERE id=%s', [t]), 'Completed')
        self.assertEqual(tr, self.accept(review, 'transition', {'target': str(t), 'assessment': str(a), 'expected_seq': 0}, 'control'))
        self.rejects(lambda: self.accept(review, 'transition', {'target': str(t), 'assessment': str(a), 'expected_seq': 0}))
        # Member-scoped correction invalidates one fit only, even across different methods.
        _, corr = self.task('correction@1')
        self.accept(corr, 'correction', {'type': 'scientific', 'target_type': 'observation', 'target': str(obs), 'member': 'A01', 'reason': 'misidentified curve'})
        self.assertFalse(sql("SELECT api.valid_assessment('a',id) FROM api.assessment WHERE output_id=%s AND member='A01'", [o], role=None))
        self.assertTrue(sql("SELECT api.valid_assessment('a',id) FROM api.assessment WHERE output_id=%s AND member='A02'", [o], role=None))

    def test_E02_wrong_well_and_missing_basis_rejected_at_admission(self):
        _, _, p = self.acquisition()
        bad = json.loads(json.dumps(p['mapping'])); bad[0]['well'] = str(fid('awell2'))
        self.rejects(lambda: self.task('acquisition@1', {'plate': str(fid('aplate')), 'mapping': bad}))
        bad = json.loads(json.dumps(p['mapping'])); bad[0].pop('basis')
        self.rejects(lambda: self.task('acquisition@1', {'plate': str(fid('aplate')), 'mapping': bad}))

    def test_E03_scientific_and_transition_failure_injection(self):
        t, e, payload = self.acquisition()
        for table in ('observation', 'task_execution_output_entity'):
            with db(None) as c:
                c.execute("CREATE OR REPLACE FUNCTION api.inject_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected'; END $$")
                c.execute(f'CREATE TRIGGER inject_failure AFTER INSERT ON api.{table} FOR EACH ROW EXECUTE FUNCTION api.inject_failure()')
            try:
                before = sql('SELECT count(*) FROM api.task_execution_output')
                self.rejects(lambda: self.accept(e, 'acquisition', payload))
                self.assertEqual(sql('SELECT count(*) FROM api.task_execution_output'), before)
                self.assertEqual(sql('SELECT count(*) FROM api.observation WHERE output_id IN (SELECT id FROM api.task_execution_output WHERE execution_id=%s)', [e]), 0)
            finally:
                with db(None) as c:
                    c.execute(f'DROP TRIGGER inject_failure ON api.{table}')
        o = self.accept(e, 'acquisition', payload)
        obs = sql('SELECT id FROM api.observation WHERE output_id=%s', [o])
        intent = {'observation': str(obs), 'member': 'A01', 'subject': str(t), 'subject_type': 'task'}
        _, review = self.task('review@1', intent)
        ro = self.accept(review, 'review', {**intent, 'outcome': 'pass'})
        a = sql('SELECT id FROM api.assessment WHERE output_id=%s', [ro])
        with db(None) as c:
            c.execute('CREATE TRIGGER inject_failure AFTER UPDATE ON api.task FOR EACH ROW EXECUTE FUNCTION api.inject_failure()')
        try:
            self.rejects(lambda: self.accept(review, 'transition', {'target': str(t), 'assessment': str(a), 'expected_seq': 0}))
            self.assertEqual(sql('SELECT state FROM api.task WHERE id=%s', [t]), 'Pending')
            self.assertEqual(sql("SELECT count(*) FROM api.task_execution_output WHERE execution_id=%s AND port='transition'", [review]), 0)
        finally:
            with db(None) as c:
                c.execute('DROP TRIGGER inject_failure ON api.task')

    def test_E04_concurrent_task_transitions(self):
        t, e, payload = self.acquisition()
        o = self.accept(e, 'acquisition', payload)
        obs = sql('SELECT id FROM api.observation WHERE output_id=%s', [o])
        intent = {'observation': str(obs), 'member': 'A01', 'subject': str(t), 'subject_type': 'task'}
        _, review = self.task('review@1', intent)
        ro = self.accept(review, 'review', {**intent, 'outcome': 'pass'})
        a = sql('SELECT id FROM api.assessment WHERE output_id=%s', [ro])
        barrier = threading.Barrier(2)
        def run(_):
            barrier.wait()
            try:
                return self.accept(review, 'transition', {'target': str(t), 'assessment': str(a), 'expected_seq': 0})
            except psycopg.Error:
                return None
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            outputs = list(pool.map(run, range(2)))
        self.assertEqual(sum(x is not None for x in outputs), 1)
        self.assertEqual(sql('SELECT seq FROM api.task WHERE id=%s', [t]), 1)

    def test_F01_exact_coordination_and_rerun_pins_history(self):
        t, e = self.task('correction@1')
        first = self.accept(e, 'terminal', {'state': 'Completed', 'reason': 'administrative review finished'})
        plan, coord = self.task('composite@1', {'dependencies': [{'role': 'preparation', 'task': str(t), 'port': 'terminal', 'spec': 'correction@1', 'mode': 'historical'}]})
        self.rejects(lambda: self.accept(coord, 'coordination', {'selections': []}))
        p = {'selections': [{'role': 'preparation', 'execution': str(e), 'output': str(first)}]}
        old = self.accept(coord, 'coordination', p)
        e2 = rpc('start_execution', task=t, workcell='w1')
        second = self.accept(e2, 'terminal', {'state': 'Completed', 'reason': 'second review'})
        self.assertEqual(sql('SELECT payload FROM api.task_execution_output WHERE id=%s', [old]), p)
        newer = self.accept(coord, 'coordination', {'selections': [{'role': 'preparation', 'execution': str(e2), 'output': str(second)}]})
        self.assertNotEqual(old, newer)
        self.rejects(lambda: self.accept(coord, 'coordination', {'selections': [{'role': 'preparation', 'execution': str(e), 'output': str(second)}]}))
        self.rejects(lambda: self.task('composite@1', {'dependencies': [{'role': 'cycle', 'task': str(uuid.uuid4()), 'port': 'terminal', 'spec': 'composite@1', 'mode': 'historical'}]}))

    def test_F02_exact_sequential_readiness_parallel_branches(self):
        upstream, e = self.task('correction@1')
        dependency = {'task': str(upstream), 'port': 'terminal', 'spec': 'correction@1', 'mode': 'historical'}
        pending = rpc('create_task', spec='correction@1', request_key=self.key(), intent={'dependencies': [dependency]})
        self.rejects(lambda: rpc('start_execution', task=pending, workcell='w1'))
        out = self.accept(e, 'terminal', {'state': 'Completed', 'reason': 'reviewed'})
        exact = {**dependency, 'output': str(out), 'execution': str(e)}
        a, ea = self.task('correction@1', {'dependencies': [exact]})
        b, eb = self.task('correction@1', {'dependencies': [exact]})
        self.accept(ea, 'terminal', {'state': 'Completed', 'reason': 'branch A'})
        self.assertEqual(sql('SELECT state FROM api.task_execution WHERE id=%s', [eb]), 'Running')
        self.accept(eb, 'terminal', {'state': 'Completed', 'reason': 'branch B'})

    def test_F03_live_scientific_prerequisite_rechecked_at_command(self):
        t, e, payload = self.acquisition()
        o = self.accept(e, 'acquisition', payload)
        obs = sql('SELECT id FROM api.observation WHERE output_id=%s', [o])
        intent = {'observation': str(obs), 'member': 'A01', 'subject': str(t), 'subject_type': 'task'}
        rt, review = self.task('review@1', intent)
        ro = self.accept(review, 'review', {**intent, 'outcome': 'pass'})
        self.receipt(47, 20)
        dep = {'role': 'qc', 'task': str(rt), 'execution': str(review), 'output': str(ro), 'member': 'A01', 'port': 'review', 'spec': 'review@1', 'mode': 'live'}
        _, downstream = self.task('transfer@1', {'dependencies': [dep], 'items': [{'key': 'well-1', 'source': str(fid('aholding47')), 'destination': str(fid('aholding48')), 'quantity': 5, 'unit': 'uL'}]})
        _, corr = self.task('correction@1')
        self.accept(corr, 'correction', {'type': 'scientific', 'target_type': 'observation', 'target': str(obs), 'member': 'A01', 'reason': 'relevant correction after admission'})
        self.rejects(lambda: self.command(downstream))
        self.assertEqual(self.balance(47), 20)

    def test_G01_usable_recorded_expiration_restriction_unknown(self):
        self.receipt(20, 50)
        yes = rpc('usability', holding=fid('aholding20'), quantity=10, intended_use='transfer')
        self.assertEqual(yes['status'], 'Yes')
        unknown = rpc('usability', holding=fid('aholding20'), quantity=10, intended_use='binding')
        self.assertEqual((unknown['status'], unknown['usable_quantity']), ('Unknown', 0))
        _, corr = self.task('correction@1')
        self.accept(corr, 'correction', {'type': 'restrict', 'holding': str(fid('aholding20'))})
        no = rpc('usability', holding=fid('aholding20'), quantity=10, intended_use='transfer')
        self.assertEqual((no['status'], no['recorded_quantity'], no['usable_quantity']), ('No', 50, 0))
        _, e = self.transfer(20, 21, 10)
        self.rejects(lambda: self.command(e))
        sql("UPDATE api.container_content SET expires_at=clock_timestamp()-interval '1 second' WHERE id=%s RETURNING id", [fid('aholding21')], role=None)
        self.assertEqual(rpc('usability', holding=fid('aholding21'), quantity=1, intended_use='transfer')['status'], 'No')

    def test_G02_transitive_correction_racing_initiation(self):
        self.receipt(385, 50)
        self.receipt(386, 10)
        _, e = self.transfer(385, 386, 5)
        self.assertEqual(rpc('usability', holding=fid('aholding385'), quantity=5, intended_use='transfer')['status'], 'Yes')
        _, corr = self.task('correction@1')
        correction = {'type': 'scientific', 'target_type': 'assessment', 'target': str(fid('aqc1')), 'reason': 'source identity incorrect'}
        with db() as c:
            c.execute('SELECT api.accept(%s,%s,%s,%s)', [corr, 'source-correction', 'correction', Jsonb(correction)])
            # Correction owns the common lock but is uncommitted. Initiation must wait, then reread.
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                future = pool.submit(self.command, e)
                for _ in range(100):
                    if sql("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted", role=None):
                        break
                    time.sleep(.01)
                else:
                    self.fail('initiation did not wait for correction lock')
                c.commit()
                with self.assertRaises(psycopg.Error):
                    future.result(timeout=5)
        affected = rpc('usability', holding=fid('aholding385'), quantity=5, intended_use='transfer')
        unaffected = rpc('usability', holding=fid('aholding386'), quantity=5, intended_use='transfer')
        self.assertEqual((affected['status'], affected['recorded_quantity'], affected['usable_quantity']), ('Unknown', 50, 0))
        self.assertEqual(unaffected['status'], 'Yes')

    def test_H01_postgrest_tenant_isolation_and_claim_spoofing(self):
        status, rows = http('/container_content?select=tenant_id,id')
        self.assertEqual(status, 200)
        self.assertEqual(len(rows), 386)
        self.assertTrue(all(r['tenant_id'] == 'a' for r in rows))
        status, rows = http('/assessment?select=tenant_id', tenant_id='b')
        self.assertEqual(status, 200)
        self.assertTrue(all(r['tenant_id'] == 'a' for r in rows))
        status, rows = http('/container_content?id=eq.' + str(fid('bholding1')))
        self.assertEqual(rows, [])
        status, result = http('/rpc/usability', {'holding': str(fid('bholding1')), 'quantity': 1, 'intended_use': 'transfer'}, tenant_id='b')
        self.assertGreaterEqual(status, 400)
        status, result = http('/material_balance', {'tenant_id': 'a', 'holding_id': str(fid('aholding1')), 'amount': 999})
        self.assertGreaterEqual(status, 400)
        status, _ = http('/rpc/guard', {})
        self.assertGreaterEqual(status, 400)
        status, _ = http('/container_content', role='anonymous')
        self.assertGreaterEqual(status, 400)
        status, _ = http('/container_content', role='modelj_owner')
        self.assertGreaterEqual(status, 400)

    def test_H02_cross_tenant_inputs_and_science(self):
        self.rejects(lambda: self.task('transfer@1', {'items': [{'key': 'x', 'source': str(fid('aholding1')), 'destination': str(fid('bholding1')), 'quantity': 1, 'unit': 'uL'}]}))
        self.rejects(lambda: self.task('processing@3', {'observation': str(fid('bqc-observation'))}))
        self.assertEqual(sql("SELECT count(*) FROM api.assessment WHERE tenant_id='b'"), 0)
        self.rejects(lambda: self.task('composite@1', {'dependencies': [{'role': 'foreign', 'task': str(fid('aenrollment-task')), 'spec': 'review@1', 'port': 'review', 'mode': 'historical', 'output': str(fid('benrollment-output')), 'execution': str(fid('benrollment-execution'))}]}))

    def test_H03_wrong_workcell_site_and_authorized_movement(self):
        self.receipt(22, 30)
        t, e = self.transfer(22, 23, 5)
        wrong = rpc('start_execution', task=t, workcell='w2')
        self.rejects(lambda: self.command(wrong))
        # Administrative fixture relocations isolate the boundary check; no placement RPC is claimed.
        sql('UPDATE api.container SET parent_id=NULL,location_id=%s,fixed=false WHERE id=%s RETURNING id', [fid('aloc3'), fid('awell23')], role=None)
        self.rejects(lambda: self.command(e))
        sql('UPDATE api.container SET parent_id=%s,location_id=NULL,fixed=true WHERE id=%s RETURNING id', [fid('aplate'), fid('awell23')], role=None)
        self.settle(e, self.command(e), 'full', 5)
        self.assertEqual(self.balance(23), 5)

    def test_H04_http_receipt_and_retry(self):
        intent = {'supplier': 'verified-supplier', 'delivery': 'HTTP-delivery', 'line': '1', 'lot': 'HTTP-lot', 'coa': {'version': 'v1'}, 'holding': str(fid('aholding30')), 'quantity': 12, 'unit': 'uL'}
        status, out = http('/rpc/register_receipt', {'request_key': 'HTTP-request', 'intent': intent, 'workcell': 'w1', 'evidence': 'signed scan'})
        self.assertEqual(status, 200, out)
        status, retry = http('/rpc/register_receipt', {'request_key': 'HTTP-request-new', 'intent': intent, 'workcell': 'w1', 'evidence': 'signed scan'})
        self.assertEqual((status, retry), (200, out))
        status, rows = http('/material_balance?holding_id=eq.' + str(fid('aholding30')) + '&select=amount')
        self.assertEqual((status, rows[0]['amount']), (200, 12))
        status, _ = http('/rpc/register_receipt', {'request_key': 'HTTP-attack', 'intent': {**intent, 'delivery': 'another', 'holding': str(fid('bholding30'))}, 'workcell': 'w1', 'evidence': 'scan'}, tenant_id='b')
        self.assertGreaterEqual(status, 400)

    def test_I01_failure_injection_atomicity(self):
        # Test-only triggers run inside the same acceptance transaction, as the owner.
        for table in ('material_movement', 'material_posting', 'material_balance'):
            self.receipt(24 if table == 'material_movement' else 25 if table == 'material_posting' else 26, 10)
            src = {'material_movement': 24, 'material_posting': 25, 'material_balance': 26}[table]
            _, e = self.transfer(src, src+100, 5)
            cmd = self.command(e)
            with db(None) as c:
                c.execute("CREATE OR REPLACE FUNCTION api.inject_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected'; END $$")
                c.execute(f'CREATE TRIGGER inject_failure AFTER {"UPDATE" if table == "material_balance" else "INSERT"} ON api.{table} FOR EACH ROW EXECUTE FUNCTION api.inject_failure()')
            try:
                before = sql('SELECT count(*) FROM api.task_execution_output')
                self.rejects(lambda: self.settle(e, cmd, 'full', 5))
                self.assertEqual(sql('SELECT count(*) FROM api.task_execution_output'), before)
                self.assertEqual(self.balance(src), 10)
                self.assertEqual(self.balance(src+100), 0)
            finally:
                with db(None) as c:
                    c.execute(f'DROP TRIGGER inject_failure ON api.{table}')
            self.settle(e, cmd, 'full', 5)
        self.assertTrue(rpc('verify_balances'))

    def test_I02_concurrent_duplicate_acceptance(self):
        self.receipt(27, 20)
        _, e = self.transfer(27, 28, 5)
        cmd = self.command(e)
        barrier = threading.Barrier(2)
        def run(_):
            barrier.wait()
            return self.settle(e, cmd, 'full', 5, 'parallel-same')
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(run, range(2)))
        self.assertEqual(results[0], results[1])
        self.assertEqual((self.balance(27), self.balance(28)), (15, 5))

    def test_I04_terminal_update_failure_rolls_back_manifest(self):
        _, e = self.task('correction@1')
        with db(None) as c:
            c.execute('CREATE TRIGGER inject_failure AFTER UPDATE ON api.task_execution FOR EACH ROW EXECUTE FUNCTION api.inject_failure()')
        try:
            self.rejects(lambda: self.accept(e, 'terminal', {'state': 'Failed', 'reason': 'injected'}))
            self.assertEqual(sql('SELECT state FROM api.task_execution WHERE id=%s', [e]), 'Running')
            self.assertEqual(sql('SELECT count(*) FROM api.task_execution_output WHERE execution_id=%s', [e]), 0)
        finally:
            with db(None) as c:
                c.execute('DROP TRIGGER inject_failure ON api.task_execution')

    def test_I03_repeatable_read_not_supported(self):
        def attempt():
            with db() as c:
                c.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
                c.execute('SELECT api.verify_balances()')
        self.rejects(attempt)


if __name__ == '__main__':
    unittest.main(verbosity=2)
