#!/usr/bin/env python3
"""Export authenticated PostgREST Swagger 2.0 as formatted JSON, never a JWT.
Only documentation metadata is adjusted: reachable host and bearer-header help.
Endpoint/schema descriptions otherwise remain PostgREST-generated.
"""
import sys
import json
import os
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from demo_auth import token


def main():
    if len(sys.argv)>2:
        raise SystemExit('Usage: python3 scripts/export_openapi.py [output.json]')
    output = Path(sys.argv[1] if len(sys.argv)==2 else 'docs/openapi.json')
    base = os.getenv('API_URL','http://localhost:53000')
    req = Request(base+'/',headers={'Authorization':'Bearer '+token('tenant_a'),'Accept':'application/openapi+json'})
    with urlopen(req,timeout=15) as response:
        document = json.load(response)
    if document.get('swagger')!='2.0' or not document.get('paths'):
        raise SystemExit('Expected PostgREST Swagger 2.0 document')
    server = urlsplit(base)
    document['host'] = server.netloc
    document['schemes'] = [server.scheme]
    document['info']['title'] = 'Model J PostgreSQL Inventory API'
    document['securityDefinitions'] = {'BearerAuth':{'type':'apiKey','name':'Authorization','in':'header',
        'description':'Supply Bearer <JWT>. Generate a local demo JWT with python3 scripts/token.py tenant_a. No token is stored in this document.'}}
    document['security'] = [{'BearerAuth':[]}]
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(document,indent=2)+'\n')
    print(f'{output}: Swagger 2.0, {len(document["paths"])} paths; no credentials embedded')


if __name__=='__main__':
    main()
