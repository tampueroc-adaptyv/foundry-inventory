#!/usr/bin/env python3
"""LOCAL DEMO ONLY. Production tokens must come from a trusted identity issuer."""
import base64
import hashlib
import hmac
import json
import sys
import time


def token(role):
    if role not in ('tenant_a', 'tenant_b'):
        raise ValueError('unsupported demo role')
    enc = lambda x: base64.urlsafe_b64encode(json.dumps(x, separators=(',', ':')).encode()).rstrip(b'=')
    data = enc({'alg': 'HS256', 'typ': 'JWT'}) + b'.' + enc({'role': role, 'exp': int(time.time()) + 3600})
    signature = base64.urlsafe_b64encode(hmac.new(b'modelj-local-test-secret-at-least-32-characters', data, hashlib.sha256).digest()).rstrip(b'=')
    return (data + b'.' + signature).decode()


if __name__ == '__main__':
    print(token(sys.argv[1] if len(sys.argv) > 1 else 'tenant_a'))
