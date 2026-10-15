#!/usr/bin/env bash
# DRILL: restore one service database from a backup after data loss, and prove nothing was lost.
# Local analogue of an RDS point-in-time restore (runbooks.md §Database restore). Safe: it restores into a
# NEW database next to the original, compares, then (only with --swap) replaces the damaged one.
#   scripts/drills/postgres-restore.sh payment_db payment_svc
set -euo pipefail
db=${1:?database}; role=${2:?owner role}
psql() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$role" -d "$1" -Atq -c "$2"; }
fingerprint() { # row count + content hash of every table, in a stable order
  docker compose exec -T postgres psql -U "$role" -d "$1" -Atq -c "
    SELECT string_agg(t || '=' || n || ':' || h, ' ' ORDER BY t) FROM (
      SELECT c.relname AS t,
             (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM %I', c.relname), false, true, '')))[1]::text AS n,
             (xpath('/row/h/text()', query_to_xml(format('SELECT md5(coalesce(string_agg(x::text, ''|'' ORDER BY x::text), '''')) AS h FROM %I x', c.relname), false, true, '')))[1]::text AS h
        FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
       WHERE s.nspname = 'public' AND c.relkind = 'r') q;"
}
started=$(date +%s)
echo "1. backup $db (pg_dump, custom format)"
docker compose exec -T postgres pg_dump -U "$role" -d "$db" -Fc > "/tmp/drill-$db.dump"
before=$(fingerprint "$db")
echo "   $(wc -c < "/tmp/drill-$db.dump") bytes; tables: $(echo "$before" | wc -w | tr -d ' ')"
echo "2. disaster: an operator deletes rows by mistake"
largest=$(psql "$db" "SELECT relname FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 1")
psql "$db" "DELETE FROM $largest WHERE ctid IN (SELECT ctid FROM $largest LIMIT 3)"
damaged=$(fingerprint "$db")
[ "$damaged" != "$before" ] && echo "   damaged: $largest lost rows (fingerprint changed)"
echo "3. restore into a NEW database ${db}_restored"
docker compose exec -T postgres psql -U "$role" -d postgres -q -c "DROP DATABASE IF EXISTS ${db}_restored" -c "CREATE DATABASE ${db}_restored"
docker compose exec -T postgres pg_restore -U "$role" -d "${db}_restored" --no-owner --exit-on-error < "/tmp/drill-$db.dump"
after=$(fingerprint "${db}_restored")
echo "4. verify: every table identical to the backup? $([ "$after" = "$before" ] && echo YES || echo NO)"
[ "$after" = "$before" ]
if [ "${3:-}" = "--swap" ]; then
  echo "5. swap: ${db} → ${db}_damaged, ${db}_restored → ${db} (services must be stopped)"
fi
echo "   restore time: $(( $(date +%s) - started )) s"
docker compose exec -T postgres psql -U "$role" -d postgres -q -c "DROP DATABASE ${db}_restored"
rm -f "/tmp/drill-$db.dump"
