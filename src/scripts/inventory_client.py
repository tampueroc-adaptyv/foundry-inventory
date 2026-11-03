"""Small standard-library HTTP client shared by the physical demo and integration tests.
No authoritative decisions live here: every operation is an RPC/database transaction.
"""
import json
import os
import urllib.error
import urllib.request
import uuid
from demo_auth import token


class APIError(Exception):
    def __init__(self, status, body):
        self.status, self.body = status, body
        super().__init__(f'{status}: {body}')


class InventoryClient:
    def __init__(self, role='tenant_b'):
        self.base = os.getenv('API_URL', 'http://localhost:53000')
        self.auth = token(role)
        self.prefix = 'inventory-' + uuid.uuid4().hex

    def key(self):
        return self.prefix + '-' + uuid.uuid4().hex

    def request(self, path, data=None, method=None):
        req = urllib.request.Request(self.base + path, data=None if data is None else json.dumps(data).encode(),
                                     headers={'Authorization': 'Bearer ' + self.auth, 'Content-Type': 'application/json'}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            with e:
                raise APIError(e.code, json.load(e)) from None

    def rpc(self, name, **args):
        return self.request('/rpc/' + name, args)

    def output(self, out):
        return self.request('/task_execution_output?id=eq.' + out)[0]

    def open(self, spec, intent, wc='w1', key=None):
        return self.rpc('open_inventory_task', spec=spec, request_key=key or self.key(), intent=intent, workcell=wc)

    def accept(self, execution, phase, payload, key=None):
        return self.rpc('inventory_accept', execution=execution, request_key=key or self.key(), phase=phase, payload=payload)

    def register(self, intent, wc='w1'):
        e = self.open('inventory-register@1', intent, wc)
        o = self.accept(e, 'register', {'confirmed': True, 'evidence': 'verified operator enrollment'})
        self.finish(e)
        return self.output(o)['payload']

    def container(self, location, spec='tube@1', parent=None, position=None, wc='w1'):
        intent = {'operation': 'container', 'spec': spec, 'barcode': self.key(), 'position': position or self.key()[-20:]}
        intent.update({'parent': parent} if parent else {'location': location})
        return self.register(intent, wc)

    def stock(self, container):
        return self.register({'operation': 'stock', 'material_spec': 'purchased-powder@1', 'container': container,
                              'label': 'supplier soluble powder', 'supplier_identity': {'supplier': 'verified-supplier', 'lot': 'LOT-42'}})

    def holding(self, material, container, wc='w1'):
        return self.register({'operation': 'holding', 'material': material, 'container': container}, wc)

    def receive(self, holding, quantity=10, unit='mg', key=None):
        return self.rpc('register_receipt', request_key=key or self.key(), intent={
            'supplier': 'verified-supplier', 'delivery': key or self.key(), 'line': '1', 'lot': 'LOT-42',
            'coa': {'bucket': 'mock-s3', 'key': 'coa/LOT-42', 'version': 'coa-v1', 'sha256': 'c'*64},
            'holding': holding, 'quantity': quantity, 'unit': unit}, workcell='w1', evidence='verified received quantity and supplier scan')

    def command(self, execution, key=None):
        return self.accept(execution, 'command', {'command_id': self.key(), 'protocol': 'external-fence-v1', 'evidence': 'operator ready; adapter must deduplicate this command'}, key)

    def effect(self, execution, phase, command, quantity=None, unit=None, key=None, **extra):
        p = {'command': command, 'evidence': 'independently confirmed physical report', 'fence_retired': True,
             'confirmed': phase!='unknown', 'outcome': 'unknown' if phase=='unknown' else 'zero' if phase=='zero' else 'confirmed', **extra}
        if quantity is not None:
            p['quantity'] = quantity
        if unit is not None:
            p['unit'] = unit
        return self.accept(execution, phase, p, key)

    def finish(self, e, state='Completed'):
        return self.rpc('accept', execution=e, request_key=self.key(), port='terminal', payload={'state': state, 'reason': 'operator accepted terminal knowledge'})

    def current(self, holding):
        return self.rpc('current_inventory', holding=holding)[0]

    def prepare(self, source, destination, quantity=10, output_quantity=200):
        e = self.open('reconstitute@1', {'source': source, 'destination': destination, 'quantity': quantity, 'unit': 'mg',
            'output_quantity': output_quantity, 'output_unit': 'uL', 'method': 'reconstitute@1', 'reason': 'one-shot reconstitution'})
        cmd = self.command(e)
        input_o = self.effect(e, 'input', cmd, quantity, 'mg')
        output_o = self.effect(e, 'output', cmd, output_quantity, 'uL', key='confirmed-product')
        terminal = self.finish(e)
        return self.output(output_o)['payload'], {'execution': e, 'command': cmd, 'input': input_o, 'output': output_o, 'terminal': terminal}

    def aliquot(self, source, destination, quantity):
        task = self.rpc('create_task', spec='transfer@1', request_key=self.key(), intent={'items': [
            {'key': 'aliquot', 'source': source, 'destination': destination, 'quantity': quantity, 'unit': 'uL'}]})
        e = self.rpc('start_execution', task=task, workcell='w1')
        cmd = self.rpc('accept', execution=e, request_key='command', port='command', payload={'command_id': self.key(), 'protocol': 'external-fence-v1'})
        p = {'command': cmd, 'key': 'aliquot', 'outcome': 'full', 'quantity': quantity, 'fence_retired': True, 'evidence': 'confirmed aliquot report'}
        o = self.rpc('accept', execution=e, request_key='settlement', port='settlement', payload=p)
        self.rpc('accept', execution=e, request_key='checkpoint', port='checkpoint', payload={'name': 'verified', 'evidence': 'verified'})
        self.finish(e)
        return {'execution': e, 'output': o, 'payload': p}

    def withdraw(self, source, quantity, phase='consume', wc='w1', unit='uL'):
        e = self.open(phase+'@1', {'source': source, 'quantity': quantity, 'unit': unit, 'reason': 'assay input' if phase=='consume' else 'evidenced waste disposal'}, wc)
        cmd = self.command(e)
        o = self.effect(e, phase, cmd, quantity, unit)
        self.finish(e)
        return o

    def close(self, holding, wc='w1'):
        task = self.rpc('create_task', spec='correction@1', request_key=self.key(), intent={})
        e = self.rpc('start_execution', task=task, workcell=wc)
        return self.rpc('accept', execution=e, request_key='closure', port='correction', payload={'type': 'close_holding', 'holding': holding})
