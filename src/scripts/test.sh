#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DB_PORT="${DB_PORT:-55432}"
export API_PORT="${API_PORT:-53000}"
export DATABASE_URL="${DATABASE_URL:-postgresql://postgres:modelj@localhost:${DB_PORT}/modelj}"
export API_URL="${API_URL:-http://localhost:${API_PORT}}"
./scripts/reset.sh
[[ -d .venv ]] || python3 -m venv .venv
.venv/bin/python -m pip -q install -r requirements-test.txt
.venv/bin/python - <<'PY'
import sys, time
sys.path.insert(0, 'tests')
from test_modelj import http
for _ in range(60):
    try:
        if http('/container_content?select=id&limit=1')[0] == 200:
            break
    except OSError:
        pass
    time.sleep(.5)
else:
    raise SystemExit('PostgREST not ready')
PY
mkdir -p artifacts
.venv/bin/python -m unittest discover -s tests -v 2>&1 | tee artifacts/test-results.txt
