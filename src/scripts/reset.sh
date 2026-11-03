#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Destructive only to this Compose project's demonstration database.
docker compose up -d --wait db
for i in {1..30}; do docker compose exec -T db pg_isready -U postgres -d modelj >/dev/null && break; sleep 1; done
docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS modelj WITH (FORCE)' -c 'CREATE DATABASE modelj'
# Roles are cluster scoped; reset them after dropping their only demonstration DB.
docker compose exec -T db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'DROP ROLE IF EXISTS authenticator, tenant_a, tenant_b, anonymous, modelj_owner'
for sql in migrations/*.sql fixtures/seed.sql; do
  echo "Applying $sql"
  docker compose exec -T db psql -U postgres -d modelj -v ON_ERROR_STOP=1 < "$sql"
done
docker compose up -d api
