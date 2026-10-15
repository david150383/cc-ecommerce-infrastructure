"""Verifies the SNS -> SQS routing configured in the local emulator (Floci), WITHOUT touching live queues.

For every real subscription of an inbox queue (saga-inbox, notification-inbox) it creates a temporary probe
queue subscribed to the same topic with the SAME filter policy and raw delivery setting (read from SNS),
publishes each service's example events, and checks that each probe received exactly the message types the
real queue would. The probes are deleted afterwards. Safe while the services are running.

Prerequisites: Floci up and `terraform apply` done (environments/local); sibling repositories checked out.
"""
import json
import os
import subprocess
import sys
import time
import uuid

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
E = os.environ.get("AWS_EMULATOR_URL", "http://localhost:4566")
os.environ.update(AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="test", AWS_DEFAULT_REGION="us-east-1")
PREFIX, ACCOUNT = "local-ecommerce", "000000000000"


def aws(*args):
    out = subprocess.run(["aws", "--endpoint-url", E, *args, "--output", "json"], check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else {}


def topic_arn(name):
    return f"arn:aws:sns:us-east-1:{ACCOUNT}:{PREFIX}-{name}"


INBOXES = {"saga-inbox": "OrderConfirmed PaymentSucceeded", "notification-inbox": "InventoryLowStock OrderConfirmed UserRegistered"}
EVENTS = [  # topic, example, messageType
    ("order-events", "ecommerce-order-service/events/examples/order-confirmed.v1.json", "OrderConfirmed"),
    ("order-events", "ecommerce-order-service/events/examples/order-created.v1.json", "OrderCreated"),
    ("payment-events", "ecommerce-payment-service/events/examples/payment-succeeded.v1.json", "PaymentSucceeded"),
    ("payment-events", "ecommerce-payment-service/events/examples/payment-initiated.v1.json", "PaymentInitiated"),
    ("inventory-events", "ecommerce-inventory-service/events/examples/inventory-low-stock.v1.json", "InventoryLowStock"),
    ("auth-events", "ecommerce-auth-service/events/examples/user-registered.v1.json", "UserRegistered"),
]

run = uuid.uuid4().hex[:8]
created_queues, created_subs = [], []
fail = 0
try:
    probes = {}
    for inbox in INBOXES:
        real_arn = f"arn:aws:sqs:us-east-1:{ACCOUNT}:{PREFIX}-{inbox}"
        probe_url = aws("sqs", "create-queue", "--queue-name", f"probe-{run}-{inbox}")["QueueUrl"]
        created_queues.append(probe_url)
        probe_arn = aws("sqs", "get-queue-attributes", "--queue-url", probe_url, "--attribute-names", "QueueArn")["Attributes"]["QueueArn"]
        probes[inbox] = probe_url
        copied = 0
        for topic in {t for t, _, _ in EVENTS}:
            for sub in aws("sns", "list-subscriptions-by-topic", "--topic-arn", topic_arn(topic)).get("Subscriptions", []):
                if sub["Endpoint"] != real_arn:
                    continue
                attrs = aws("sns", "get-subscription-attributes", "--subscription-arn", sub["SubscriptionArn"])["Attributes"]
                copy = {"RawMessageDelivery": attrs.get("RawMessageDelivery", "false")}
                if "FilterPolicy" in attrs:
                    copy["FilterPolicy"] = attrs["FilterPolicy"]
                    copy["FilterPolicyScope"] = attrs.get("FilterPolicyScope", "MessageAttributes")
                new = aws("sns", "subscribe", "--topic-arn", topic_arn(topic), "--protocol", "sqs", "--notification-endpoint", probe_arn,
                          "--attributes", json.dumps(copy), "--return-subscription-arn")["SubscriptionArn"]
                created_subs.append(new)
                copied += 1
        print(f"probe for {inbox}: {copied} subscription(s) copied with their filter policies")

    for topic, example, mtype in EVENTS:
        with open(os.path.join(ROOT, example)) as f:
            body = f.read()
        aws("sns", "publish", "--topic-arn", topic_arn(topic), "--message", body,
            "--message-attributes", json.dumps({"messageType": {"DataType": "String", "StringValue": mtype}}))
    time.sleep(5)  # SNS -> SQS delivery is asynchronous

    for inbox, expected in INBOXES.items():
        types = []
        for _ in range(3):
            msgs = aws("sqs", "receive-message", "--queue-url", probes[inbox], "--max-number-of-messages", "10", "--wait-time-seconds", "2").get("Messages", [])
            if not msgs:
                break
            for m in msgs:
                body = json.loads(m["Body"])
                if "TopicArn" in body:
                    print(f"FAIL {inbox}: message arrived SNS-wrapped (raw delivery is not enabled)")
                    fail = 1
                types.append(body.get("messageType"))
        got = " ".join(sorted(types))
        ok = got == expected
        fail |= not ok
        print(f"{'PASS' if ok else 'FAIL'} {inbox}: {'' if ok else f'expected [{expected}] '}got [{got}]")
finally:
    for s in created_subs:
        subprocess.run(["aws", "--endpoint-url", E, "sns", "unsubscribe", "--subscription-arn", s], capture_output=True)
    for q in created_queues:
        subprocess.run(["aws", "--endpoint-url", E, "sqs", "delete-queue", "--queue-url", q], capture_output=True)
sys.exit(fail)
