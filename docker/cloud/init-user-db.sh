#!/usr/bin/env bash
# init-user-db.sh — runs once inside postgres at first boot (empty data dir).
# We run Immich as a NON-superuser (DB_USERNAME), so pre-create the extensions
# its migrations need here, while we still are superuser. Immich needs all
# three: vector (similarity search), cube + earthdistance (map / geo queries).
# With them pre-installed, later migrations succeed as a plain user.
# Env comes from compose: POSTGRES_USER/POSTGRES_DB hold the Immich values.
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance;
EOSQL
