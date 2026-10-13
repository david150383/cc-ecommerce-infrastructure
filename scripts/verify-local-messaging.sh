#!/usr/bin/env bash
# Verifies the SNS -> SQS topology in LocalStack: publishes each service's example
# events and checks that every inbox queue receives exactly the message types its
# filter policies allow, as raw (unwrapped) envelopes.
#
# Prerequisites:
#   docker compose up -d localstack
#   (cd terraform/environments/local && terraform init && terraform apply)
# Sibling service repositories must be checked out next to this one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
ls_aws() { aws --endpoint-url "${LOCALSTACK_URL:-http://localhost:4566}" "$@"; }
ACCOUNT=000000000000
PREFIX=local-ecommerce

queue_url() { ls_aws sqs get-queue-url --queue-name "$PREFIX-$1" --query QueueUrl --output text; }

publish() { # topic, example file, messageType
  ls_aws sns publish --topic-arn "arn:aws:sns:us-east-1:$ACCOUNT:$PREFIX-$1" --message "file://$ROOT/$2" \
    --message-attributes "{\"messageType\":{\"DataType\":\"String\",\"StringValue\":\"$3\"}}" >/dev/null
}

received_types() { # queue -> sorted, space-separated messageTypes (fails on SNS-wrapped bodies)
  ls_aws sqs receive-message --queue-url "$(queue_url "$1")" --max-number-of-messages 10 --wait-time-seconds 5 --output json |
    python3 -c '
import json, sys
raw = sys.stdin.read().strip()
types = []
for m in (json.loads(raw).get("Messages", []) if raw else []):
    body = json.loads(m["Body"])
    if "TopicArn" in body:
        sys.exit("message arrived SNS-wrapped; raw delivery is not enabled")
    types.append(body["messageType"])
print(" ".join(sorted(types)))'
}

for q in saga-inbox notification-inbox; do ls_aws sqs purge-queue --queue-url "$(queue_url $q)"; done
sleep 2

publish order-events     ecommerce-order-service/events/examples/order-confirmed.v1.json         OrderConfirmed
publish order-events     ecommerce-order-service/events/examples/order-created.v1.json           OrderCreated
publish payment-events   ecommerce-payment-service/events/examples/payment-succeeded.v1.json     PaymentSucceeded
publish payment-events   ecommerce-payment-service/events/examples/payment-initiated.v1.json     PaymentInitiated
publish inventory-events ecommerce-inventory-service/events/examples/inventory-low-stock.v1.json InventoryLowStock
publish auth-events      ecommerce-auth-service/events/examples/user-registered.v1.json          UserRegistered

# SNS -> SQS delivery is asynchronous; never assume a publish is immediately visible.
sleep 5

fail=0
check() { # queue, expected
  local got; got="$(received_types "$1")"
  if [[ "$got" == "$2" ]]; then echo "PASS $1: $got"; else echo "FAIL $1: expected [$2] got [$got]"; fail=1; fi
}
check saga-inbox         "OrderConfirmed PaymentSucceeded"
check notification-inbox "InventoryLowStock OrderConfirmed UserRegistered"
exit $fail
