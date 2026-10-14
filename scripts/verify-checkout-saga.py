"""End-to-end checkout through the REAL services (Phase 3): Auth, Product, Inventory, Order and the Saga
Orchestrator in containers, talking over Floci SNS/SQS.

The Payment Service arrives in Phase 4. Until then this script plays its two parts:
  - a stub for POST /api/v1/payments/intent (the saga's synchronous call), on host port 4105
  - PaymentSucceeded / PaymentFailed events published to the real payment-events topic

Prerequisites (see docs/architecture/local-development.md):
  SAGA_PAYMENT_SERVICE_URL=http://host.docker.internal:4105 SAGA_PAYMENT_TIMEOUT_SECONDS=15 \\
    docker compose --profile apps up -d
  demo catalog seeded; admin@shop.local exists (password via ADMIN_PASSWORD below)
    ADMIN_PASSWORD='…' python3 scripts/verify-checkout-saga.py
"""
import json
import os
import subprocess
import sys
import threading
import time
import uuid
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

A, I, O, S = "http://localhost:4001", "http://localhost:4003", "http://localhost:4004", "http://localhost:4007"
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "shop owner passphrase 2026")
os.environ.update(AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="test", AWS_DEFAULT_REGION="us-east-1")
COMPOSE_DIR = os.path.join(os.path.dirname(__file__), "..")


# ----------------------------------------------------------------------------- payment stand-in
class PaymentStub(BaseHTTPRequestHandler):
    intents: dict[str, str] = {}  # orderId -> paymentId

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        payment_id = PaymentStub.intents.setdefault(body["orderId"], str(uuid.uuid4()))
        out = json.dumps({"payment": {"id": payment_id, "checkoutUrl": f"https://pay.example/checkout/{payment_id}"}}).encode()
        self.send_response(201)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


def publish_payment_event(kind, saga_id, order_id, customer_id, amount_minor):
    payment_id = PaymentStub.intents[order_id]
    payload = {"paymentId": payment_id, "orderId": order_id, "customerId": customer_id,
               "amount": {"amountMinor": amount_minor, "currency": "INR"}, "provider": "mock"}
    payload.update({"providerPaymentRef": "mock_e2e"} if kind == "PaymentSucceeded" else {"failureCode": "DECLINED"})
    envelope = {"messageId": str(uuid.uuid4()), "messageKind": "event", "messageType": kind, "messageVersion": 1,
                "producer": "ecommerce-payment-service", "occurredAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
                "correlationId": saga_id, "causationId": None, "sagaId": saga_id, "idempotencyKey": None, "payload": payload}
    subprocess.run(["aws", "--endpoint-url", "http://localhost:4566", "sns", "publish",
                    "--topic-arn", "arn:aws:sns:us-east-1:000000000000:local-ecommerce-payment-events",
                    "--message", json.dumps(envelope),
                    "--message-attributes", json.dumps({"messageType": {"DataType": "String", "StringValue": kind}})],
                   check=True, capture_output=True)


# ----------------------------------------------------------------------------- helpers
def call(method, url, body=None, token=None, key=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("content-type", "application/json")
    if token:
        req.add_header("authorization", f"Bearer {token}")
    if key:
        req.add_header("idempotency-key", key)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def login(email, password):
    s, b = call("POST", f"{A}/api/v1/auth/login", {"email": email, "password": password})
    assert s == 200, (s, b)
    return b["accessToken"], b["user"]["id"]


def wait_for(token, saga_id, statuses, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        _, b = call("GET", f"{S}/api/v1/checkout/{saga_id}", token=token)
        if b.get("status") in statuses:
            return b
        time.sleep(0.5)
    raise AssertionError(f"saga {saga_id} did not reach {statuses}; last: {b}")


def stock(admin, sku):
    _, b = call("GET", f"{I}/api/v1/inventory/{sku}", token=admin)
    return b["onHand"], b["reserved"]


def order_status(token, order_id):
    return call("GET", f"{O}/api/v1/orders/{order_id}", token=token)[1]["order"]["status"]


results = []


def check(name, cond, detail=""):
    results.append(cond)
    print(f"{'✓' if cond else '✗'} {name}{f'  ({detail})' if detail else ''}")


ADDRESS = {"name": "Saga Buyer", "line1": "1 Saga St", "city": "Pune", "postalCode": "411001", "country": "IN", "phone": "+919800000003"}


def checkout(token, sku, qty):
    s, b = call("POST", f"{S}/api/v1/checkout", {"currency": "INR", "items": [{"sku": sku, "quantity": qty}], "shippingAddress": ADDRESS}, token, str(uuid.uuid4()))
    assert s == 202, (s, b)
    return b


def main():
    server = HTTPServer(("0.0.0.0", 4105), PaymentStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    admin, _ = login("admin@shop.local", ADMIN_PASSWORD)
    email = f"saga-{int(time.time())}@example.com"
    call("POST", f"{A}/api/v1/auth/register", {"email": email, "password": "a long buyer passphrase", "fullName": "Saga Buyer"})
    customer, customer_id = login(email, "a long buyer passphrase")
    sku = "TEE-CLASSIC-WHT-S"
    call("PATCH", f"{I}/api/v1/inventory/{sku}", {"delta": 5, "reason": "RESTOCK", "note": "saga e2e"}, admin, str(uuid.uuid4()))

    # 1. Happy path ------------------------------------------------------------------------------
    on_hand0, _ = stock(admin, sku)
    c = checkout(customer, sku, 1)
    w = wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT", "CANCELLED", "FAILED"})
    check("1a. checkout → order priced, stock reserved, payment intent → AWAITING_PAYMENT", w["status"] == "AWAITING_PAYMENT" and w["checkoutUrl"], w["checkoutUrl"])
    _, held = stock(admin, sku)
    publish_payment_event("PaymentSucceeded", c["sagaId"], w["orderId"], customer_id, 0)
    done = wait_for(customer, c["sagaId"], {"COMPLETED", "CANCELLED", "UNDER_REVIEW"})
    on_hand1, reserved1 = stock(admin, sku)
    check("1b. PaymentSucceeded → stock confirmed → order CONFIRMED → saga COMPLETED",
          done["status"] == "COMPLETED" and order_status(customer, w["orderId"]) == "CONFIRMED" and on_hand1 == on_hand0 - 1 and reserved1 == 0,
          f"held {held} during payment; on hand {on_hand0}→{on_hand1}")

    # 2. Out of stock -----------------------------------------------------------------------------
    c = checkout(customer, sku, 999)
    f = wait_for(customer, c["sagaId"], {"CANCELLED", "FAILED", "COMPLETED"})
    check("2. out of stock → order cancelled → saga CANCELLED",
          f["status"] == "CANCELLED" and f["failureReason"] == "INSUFFICIENT_STOCK" and order_status(customer, f["orderId"]) == "CANCELLED", f["failureReason"])

    # 3. Payment declined -------------------------------------------------------------------------
    before = stock(admin, sku)
    c = checkout(customer, sku, 2)
    w = wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT"})
    publish_payment_event("PaymentFailed", c["sagaId"], w["orderId"], customer_id, 0)
    f = wait_for(customer, c["sagaId"], {"CANCELLED", "UNDER_REVIEW"})
    check("3. payment declined → stock released AND order cancelled → CANCELLED",
          f["status"] == "CANCELLED" and stock(admin, sku) == before and order_status(customer, w["orderId"]) == "CANCELLED", f"stock back to {before}")

    # 4. Payment never arrives (SAGA_PAYMENT_TIMEOUT_SECONDS=15) ----------------------------------
    c = checkout(customer, sku, 1)
    w = wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT"})
    f = wait_for(customer, c["sagaId"], {"CANCELLED", "UNDER_REVIEW"}, timeout=90)
    check("4. no payment → timeout → compensation → CANCELLED (PAYMENT_TIMEOUT)",
          f["status"] == "CANCELLED" and f["failureReason"] == "PAYMENT_TIMEOUT" and stock(admin, sku) == before, f["failureReason"])

    # 5. Saga crashes while the payment event arrives ---------------------------------------------
    c = checkout(customer, sku, 1)
    w = wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT"})
    subprocess.run(["docker", "compose", "--profile", "apps", "kill", "-s", "SIGKILL", "saga-orchestrator"], cwd=COMPOSE_DIR, check=True, capture_output=True)
    publish_payment_event("PaymentSucceeded", c["sagaId"], w["orderId"], customer_id, 0)  # waits in saga-inbox
    time.sleep(2)
    subprocess.run(["docker", "compose", "--profile", "apps", "up", "-d", "--no-build", "--wait", "saga-orchestrator"], cwd=COMPOSE_DIR, check=True, capture_output=True)
    done = wait_for(customer, c["sagaId"], {"COMPLETED", "CANCELLED", "UNDER_REVIEW"})
    check("5. saga SIGKILLed while the payment arrives → restarted → resumes from saga-inbox → COMPLETED",
          done["status"] == "COMPLETED" and order_status(customer, w["orderId"]) == "CONFIRMED")

    # Nothing dead-lettered -----------------------------------------------------------------------
    dlq = {}
    for q in ("saga-inbox-dlq", "inventory-commands-dlq", "order-commands-dlq.fifo"):
        out = subprocess.run(["aws", "--endpoint-url", "http://localhost:4566", "sqs", "get-queue-attributes", "--queue-url",
                              f"http://localhost:4566/000000000000/local-ecommerce-{q}", "--attribute-names", "ApproximateNumberOfMessages", "--output", "json"],
                             check=True, capture_output=True, text=True).stdout
        dlq[q] = json.loads(out)["Attributes"]["ApproximateNumberOfMessages"]
    check("6. all DLQs empty", all(v == "0" for v in dlq.values()), str(dlq))

    server.shutdown()
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
