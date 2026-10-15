#!/usr/bin/env bash
# DRILL: messages that dead-lettered during an incident are redriven once the cause is fixed, processed
# exactly once (a second redrive of the same message changes nothing). Uses the native SQS redrive API
# (start-message-move-task), the same command as in AWS (runbooks.md §Dead letters).
#   scripts/drills/dlq-redrive.sh
set -euo pipefail
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-test} AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-test} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}
E=${AWS_ENDPOINT:-http://localhost:4566}
aws() { command aws --endpoint-url "$E" "$@"; }
q="$E/000000000000/local-ecommerce-notification-commands"
dlq="$q-dlq"
arn() { aws sqs get-queue-attributes --queue-url "$1" --attribute-names QueueArn --query Attributes.QueueArn --output text; }
depth() { aws sqs get-queue-attributes --queue-url "$1" --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text; }
rows() { docker compose exec -T postgres psql -U notification_svc -d notification_db -Atc "SELECT count(*) FROM notifications WHERE dedupe_key = '$key'"; }

key="drill-redrive-$(date +%s)"
msg=$(python3 - "$key" <<'PY'
import json, sys, uuid, datetime
print(json.dumps({"messageId": str(uuid.uuid4()), "messageKind": "command", "messageType": "NotificationRequested", "messageVersion": 1,
  "producer": "ecommerce-order-service", "occurredAt": datetime.datetime.now(datetime.UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
  "correlationId": str(uuid.uuid4()), "causationId": None, "sagaId": None, "idempotencyKey": sys.argv[1],
  "payload": {"recipientUserId": str(uuid.uuid4()), "channel": "email", "templateKey": "order.shipped", "data": {"orderId": str(uuid.uuid4())}}}))
PY
)
echo "1. incident: a valid command dead-lettered (e.g. the database was down for longer than 5 receives)"
aws sqs send-message --queue-url "$dlq" --message-body "$msg" >/dev/null
sleep 1
echo "   DLQ depth: $(depth "$dlq"); notifications with this key: $(rows)"
echo "2. cause fixed; redrive the DLQ into its source queue"
task=$(aws sqs start-message-move-task --source-arn "$(arn "$dlq")" --destination-arn "$(arn "$q")" --query TaskHandle --output text)
echo "   move task: ${task:0:40}…"
for _ in $(seq 1 30); do [ "$(rows)" = "1" ] && break; sleep 1; done
echo "3. processed: notifications with this key: $(rows); DLQ depth: $(depth "$dlq")"
[ "$(rows)" = "1" ]
echo "4. the same message redriven AGAIN (someone runs the redrive twice)"
aws sqs send-message --queue-url "$dlq" --message-body "$msg" >/dev/null
aws sqs start-message-move-task --source-arn "$(arn "$dlq")" --destination-arn "$(arn "$q")" >/dev/null
sleep 8
echo "   notifications with this key: $(rows) (idempotent: still one); DLQ depth: $(depth "$dlq")"
[ "$(rows)" = "1" ]
