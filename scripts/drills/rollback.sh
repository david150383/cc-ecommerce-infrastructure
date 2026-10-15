#!/usr/bin/env bash
# DRILL: a broken release of notification-service is deployed, detected, and rolled back; work that
# arrives while it is broken waits in SQS and is processed after the rollback (no loss). Local analogue of
# an ECS rollback (runbooks.md §Rollback). In AWS the circuit breaker performs steps 3-4 by itself.
#   scripts/drills/rollback.sh
set -euo pipefail
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-test} AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-test} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
E=http://localhost:4566
img=ecommerce-notification-service
key="drill-rollback-$(date +%s)"
rows() { docker compose exec -T postgres psql -U notification_svc -d notification_db -Atc "SELECT count(*) FROM notifications WHERE dedupe_key = '$key'"; }
health() { curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:4006/health/ready || true; }

echo "1. current release is healthy (HTTP $(health)); keep it as :good (in AWS: the previous task definition revision)"
docker tag "$img:latest" "$img:good"
echo "2. deploy a broken release (crashes at startup)"
printf 'FROM %s:good\nCMD ["node", "-e", "console.error(\\"bad release: missing configuration\\"); process.exit(1)"]\n' "$img" | docker build -q -t "$img:bad" - >/dev/null
docker tag "$img:bad" "$img:latest"
docker compose --profile apps up -d --no-build --no-deps notification-service >/dev/null 2>&1
echo "3. work arrives while it is broken"
python3 - "$key" <<'PY' > /tmp/drill-msg.json
import json, sys, uuid, datetime
print(json.dumps({"messageId": str(uuid.uuid4()), "messageKind": "command", "messageType": "NotificationRequested", "messageVersion": 1,
  "producer": "ecommerce-order-service", "occurredAt": datetime.datetime.now(datetime.UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
  "correlationId": str(uuid.uuid4()), "causationId": None, "sagaId": None, "idempotencyKey": sys.argv[1],
  "payload": {"recipientUserId": str(uuid.uuid4()), "channel": "email", "templateKey": "order.shipped", "data": {"orderId": str(uuid.uuid4())}}}))
PY
aws --endpoint-url "$E" sqs send-message --queue-url "$E/000000000000/local-ecommerce-notification-commands" --message-body "file:///tmp/drill-msg.json" >/dev/null
sleep 8
echo "4. detected: readiness HTTP $(health), container: $(docker compose ps --format '{{.Status}}' notification-service), last log: $(docker compose logs --tail 1 --no-log-prefix notification-service 2>&1 | tail -1)"
echo "   processed so far: $(rows) (the message waits in SQS)"
echo "5. roll back to :good"
started=$(date +%s)
docker tag "$img:good" "$img:latest"
docker compose --profile apps up -d --no-build --no-deps --wait notification-service >/dev/null 2>&1
echo "   healthy again after $(( $(date +%s) - started )) s (HTTP $(health))"
for _ in $(seq 1 120); do [ "$(rows)" = "1" ] && break; sleep 1; done
echo "6. the message sent during the incident is processed: $(rows) notification, $(( $(date +%s) - started )) s after the rollback began"
[ "$(rows)" = "1" ]
docker image rm -f "$img:bad" "$img:good" >/dev/null; rm -f /tmp/drill-msg.json
