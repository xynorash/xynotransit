#!/usr/bin/env bash
set -euo pipefail

if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  : "${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD}"
  pwfile=$(mktemp); printf '%s' "$POSTGRES_PASSWORD" > "$pwfile"
  initdb -D "$PGDATA" -U "$POSTGRES_USER" --pwfile="$pwfile" --auth-host=scram-sha-256 --auth-local=trust >/dev/null
  rm -f "$pwfile"
  echo "host all all all scram-sha-256" >> "$PGDATA/pg_hba.conf"

  pg_ctl -D "$PGDATA" -o "-c listen_addresses='' -c unix_socket_directories=/tmp" -w start >/dev/null
  createdb -U "$POSTGRES_USER" "$POSTGRES_DB"
  for f in /initdb/*.sql; do
    echo "init: $f"
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "$f" >/dev/null
  done
  pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null
fi

exec "$@" -D "$PGDATA" -c listen_addresses='*' -c unix_socket_directories=/tmp
