#!/usr/bin/env bash
# DRILL: restore the Order Service's MongoDB database from a backup after data loss, and prove it is
# identical. Local analogue of a DocumentDB snapshot restore (runbooks.md §Database restore). Restores
# into a NEW database; the original is never touched.
#   scripts/drills/mongo-restore.sh order_db
set -euo pipefail
src=${1:?database}; copy="${src}_drill"; restored="${src}_restored"
mongo() { docker compose exec -T mongo mongosh --quiet -u root -p mongo_local_admin --authenticationDatabase admin "$@"; }
fingerprint() { # per collection: count + hash of all documents in _id order
  mongo "$1" --eval 'const out = []; for (const c of db.getCollectionNames().sort()) {
      const docs = db.getCollection(c).find().sort({ _id: 1 }).toArray();
      out.push(c + "=" + docs.length + ":" + crypto.createHash("md5").update(EJSON.stringify(docs)).digest("hex")); }
    print(out.join(" "))'
}
started=$(date +%s)
echo "0. work on a copy of $src: $copy"
docker compose exec -T mongo sh -c "mongodump -u root -p mongo_local_admin --authenticationDatabase admin --db $src --archive | mongorestore -u root -p mongo_local_admin --authenticationDatabase admin --archive --nsFrom '$src.*' --nsTo '$copy.*' --drop --quiet"
echo "1. backup $copy (mongodump archive)"
docker compose exec -T mongo mongodump -u root -p mongo_local_admin --authenticationDatabase admin --db "$copy" --archive --quiet > "/tmp/drill-$copy.archive"
before=$(fingerprint "$copy")
echo "   $(wc -c < "/tmp/drill-$copy.archive") bytes; collections: $(echo "$before" | wc -w | tr -d ' ')"
echo "2. disaster: orders deleted by mistake"
# shellcheck disable=SC2016  # $in is a MongoDB operator inside JavaScript, not a shell variable
mongo "$copy" --eval 'print("   deleted: " + db.orders.deleteMany({ _id: { $in: db.orders.find().limit(3).toArray().map((d) => d._id) } }).deletedCount + " orders")'
[ "$(fingerprint "$copy")" != "$before" ] && echo "   fingerprint changed"
echo "3. restore the backup into a NEW database $restored"
docker compose exec -T mongo mongorestore -u root -p mongo_local_admin --authenticationDatabase admin --archive --nsFrom "$copy.*" --nsTo "$restored.*" --drop --quiet < "/tmp/drill-$copy.archive"
after=$(fingerprint "$restored")
echo "4. verify: every collection identical to the backup (indexes included)? $([ "$after" = "$before" ] && echo YES || echo NO)"
[ "$after" = "$before" ]
idx_before=$(mongo "$copy" --eval 'print(JSON.stringify(db.orders.getIndexes().map((i) => i.name).sort()))')
idx_after=$(mongo "$restored" --eval 'print(JSON.stringify(db.orders.getIndexes().map((i) => i.name).sort()))')
[ "$idx_after" = "$idx_before" ] && echo "   indexes: $idx_after"
echo "   restore time: $(( $(date +%s) - started )) s"
mongo "$copy" --eval 'db.dropDatabase()' >/dev/null; mongo "$restored" --eval 'db.dropDatabase()' >/dev/null
rm -f "/tmp/drill-$copy.archive"
