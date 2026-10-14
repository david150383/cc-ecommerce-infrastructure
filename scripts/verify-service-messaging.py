"""Service messaging end-to-end (Phase 3b): does by hand, over the REAL queues, what the Saga
Orchestrator automates, and checks every result arrives in saga-inbox / notification-inbox.

Prerequisites: `docker compose --profile apps up -d` (with messaging-init done), the demo catalog
seeded and stock for TEE-CLASSIC-BLK-M (see docs/architecture/local-development.md).
    python3 scripts/verify-service-messaging.py
"""
import json, os, subprocess, sys, time, uuid, urllib.request, urllib.error

A, O = "http://localhost:4001", "http://localhost:4004"
os.environ.update(AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="test", AWS_DEFAULT_REGION="us-east-1")

def aws(*args):
    out = subprocess.run(["aws", "--endpoint-url", "http://localhost:4566", *args, "--output", "json"], capture_output=True, text=True, check=True).stdout
    return json.loads(out) if out.strip() else {}

def queue(name):  # by name; the URL host "floci" only resolves inside Docker
    name = "order-commands.fifo" if name == "order-commands" else name.replace("order-commands-dlq", "order-commands-dlq.fifo")
    return f"http://localhost:4566/000000000000/local-ecommerce-{name}"

def purge(name):
    aws("sqs", "purge-queue", "--queue-url", queue(name))

def receive(name, want, timeout=20):
    """Collect messages from a queue until `want` (a predicate on the list) holds, deleting what we read."""
    got, deadline = [], time.time() + timeout
    while time.time() < deadline and not want(got):
        r = aws("sqs", "receive-message", "--queue-url", queue(name), "--max-number-of-messages", "10", "--wait-time-seconds", "2")
        for m in r.get("Messages", []):
            got.append(json.loads(m["Body"]))
            aws("sqs", "delete-message", "--queue-url", queue(name), "--receipt-handle", m["ReceiptHandle"])
    return got

def call(method, url, body=None, token=None, key=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("content-type", "application/json")
    if token: req.add_header("authorization", f"Bearer {token}")
    if key: req.add_header("idempotency-key", key)
    try:
        with urllib.request.urlopen(req, timeout=15) as r: return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b"{}")

def command(qname, mtype, payload, saga_id, key):
    env = {"messageId": str(uuid.uuid4()), "messageKind": "command", "messageType": mtype, "messageVersion": 1,
           "producer": "ecommerce-saga-orchestrator", "occurredAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
           "correlationId": saga_id, "causationId": None, "sagaId": saga_id, "idempotencyKey": key, "payload": payload}
    fifo = ["--message-group-id", payload["orderId"], "--message-deduplication-id", env["messageId"]] if qname == "order-commands" else []
    aws("sqs", "send-message", "--queue-url", queue(qname), "--message-body", json.dumps(env),
        "--message-attributes", json.dumps({"messageType": {"DataType": "String", "StringValue": mtype}}), *fifo)
    return env

def ok(n, text, cond):
    print(f"{'✓' if cond else '✗'} {n}. {text}")
    if not cond: sys.exit(1)

for q in ("saga-inbox", "notification-inbox"): purge(q)
time.sleep(1)

# 1. Auth relay -> auth-events -> notification-inbox (filter: UserRegistered)
email = f"msg-{int(time.time())}@example.com"
s, reg = call("POST", f"{A}/api/v1/auth/register", {"email": email, "password": "a long buyer passphrase", "fullName": "Msg Buyer"})
notes = receive("notification-inbox", lambda g: any(m["payload"].get("email") == email for m in g))
ok(1, f"register → Auth outbox → SNS → notification-inbox: {[m['messageType'] for m in notes]}", any(m["messageType"] == "UserRegistered" for m in notes))
customer_id = reg["user"]["id"]

# 2. order via REST (saga service token)
s, t = call("POST", f"{A}/internal/v1/auth/service-token", {"clientId": "ecommerce-saga-orchestrator", "clientSecret": "saga-orchestrator-local-secret", "audience": "ecommerce-order-service"})
saga_id = str(uuid.uuid4())
s, b = call("POST", f"{O}/api/v1/orders", {"customerId": customer_id, "sagaId": saga_id, "currency": "INR",
          "items": [{"sku": "TEE-CLASSIC-BLK-M", "quantity": 1}],
          "shippingAddress": {"name": "Msg Buyer", "line1": "1 Queue St", "city": "Pune", "postalCode": "411001", "country": "IN", "phone": "+919800000002"}},
          t["accessToken"], str(uuid.uuid4()))
oid = b["order"]["id"]
ok(2, f"order {oid[:8]}… created (PENDING) with sagaId", s == 201)

# 3. InventoryReservationRequested over SQS -> InventoryReserved in saga-inbox
reserve = command("inventory-commands", "InventoryReservationRequested", {"orderId": oid, "lines": [{"sku": "TEE-CLASSIC-BLK-M", "quantity": 1}]}, saga_id, f"{saga_id}:reserve")
got = receive("saga-inbox", lambda g: any(m["messageType"] == "InventoryReserved" for m in g))
reserved = next(m for m in got if m["messageType"] == "InventoryReserved")
ok(3, f"inventory-commands → Inventory → SNS → saga-inbox: InventoryReserved (sagaId ✓, causationId = command ✓)",
   reserved["sagaId"] == saga_id and reserved["causationId"] == reserve["messageId"])
rid = reserved["payload"]["reservationId"]

# 4. duplicate command -> same reservation, answered again
command("inventory-commands", "InventoryReservationRequested", {"orderId": oid, "lines": [{"sku": "TEE-CLASSIC-BLK-M", "quantity": 1}]}, saga_id, f"{saga_id}:reserve")
again = receive("saga-inbox", lambda g: any(m["messageType"] == "InventoryReserved" for m in g))
ok(4, "re-sent reserve command: answered again, same reservation (no double reservation)",
   any(m["messageType"] == "InventoryReserved" and m["payload"]["reservationId"] == rid for m in again))

# 5. order transitions over SQS -> OrderConfirmed in saga-inbox AND notification-inbox
for st in ["INVENTORY_RESERVING", "INVENTORY_RESERVED", "PAYMENT_PENDING", "PAYMENT_SUCCEEDED"]:
    # Sent back to back with no waiting: the FIFO queue delivers one order's commands in send order.
    command("order-commands", "OrderStatusTransitionRequested", {"orderId": oid, "toStatus": st, "reason": "manual saga"}, saga_id, f"{saga_id}:{st}")
command("inventory-commands", "InventoryReservationConfirmRequested", {"reservationId": rid, "orderId": oid}, saga_id, f"{saga_id}:confirm")
inv = receive("saga-inbox", lambda g: any(m["messageType"] == "InventoryReservationConfirmed" for m in g))
ok(5, "confirm command → InventoryReservationConfirmed in saga-inbox", any(m["messageType"] == "InventoryReservationConfirmed" for m in inv))

command("order-commands", "OrderStatusTransitionRequested", {"orderId": oid, "toStatus": "CONFIRMED", "reason": "manual saga"}, saga_id, f"{saga_id}:CONFIRMED")
conf = receive("saga-inbox", lambda g: any(m["messageType"] == "OrderConfirmed" for m in g))
note = receive("notification-inbox", lambda g: any(m["messageType"] == "OrderConfirmed" for m in g))
ok(6, "OrderConfirmed fanned out to BOTH saga-inbox and notification-inbox",
   any(m["messageType"] == "OrderConfirmed" and m["payload"]["orderId"] == oid for m in conf) and any(m["messageType"] == "OrderConfirmed" for m in note))

# 6. nothing was dead-lettered
dlq = {n: aws("sqs", "get-queue-attributes", "--queue-url", queue(f"{n}-dlq"), "--attribute-names", "ApproximateNumberOfMessages")["Attributes"]["ApproximateNumberOfMessages"] for n in ("inventory-commands", "order-commands")}
ok(7, f"DLQs empty: {dlq}", all(v == "0" for v in dlq.values()))
