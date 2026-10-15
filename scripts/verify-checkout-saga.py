"""End-to-end checkout through the REAL services (Phase 4): Auth, Product, Inventory, Order, Payment (mock
provider) and the Saga Orchestrator in containers, talking over Floci SNS/SQS. No stubs: payments happen by
clicking Pay / Decline on the mock provider's hosted checkout page, which sends signed webhooks.

Prerequisites (see docs/architecture/local-development.md):
  SAGA_PAYMENT_TIMEOUT_SECONDS=15 docker compose --profile apps up -d
  demo catalog seeded; admin@shop.local exists (password via ADMIN_PASSWORD below)
    ADMIN_PASSWORD='…' python3 scripts/verify-checkout-saga.py
"""
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

A, I, O, P, S = "http://localhost:4001", "http://localhost:4003", "http://localhost:4004", "http://localhost:4005", "http://localhost:4007"
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "shop owner passphrase 2026")
os.environ.update(AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="test", AWS_DEFAULT_REGION="us-east-1")
COMPOSE_DIR = os.path.join(os.path.dirname(__file__), "..")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # we want to SEE the provider's 303 back to the shop, not follow it


opener = urllib.request.build_opener(NoRedirect)


# ----------------------------------------------------------------------------- helpers
def call(method, url, body=None, token=None, key=None, raw=None, headers=None, timeout=20):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("content-type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if token:
        req.add_header("authorization", f"Bearer {token}")
    if key:
        req.add_header("idempotency-key", key)
    try:
        with opener.open(req, timeout=timeout) as r:
            text = r.read()
            return r.status, (json.loads(text) if text and r.headers.get_content_type() == "application/json" else {})
    except urllib.error.HTTPError as e:
        text = e.read()
        try:
            return e.code, json.loads(text or b"{}")
        except ValueError:
            return e.code, {"location": e.headers.get("location")}


def login(email, password):
    s, b = call("POST", f"{A}/api/v1/auth/login", {"email": email, "password": password})
    assert s == 200, (s, b)
    return b["accessToken"], b["user"]["id"]


def wait_for(token, saga_id, statuses, timeout=60):
    deadline = time.time() + timeout
    b = {}
    failed = 0
    while time.time() < deadline:
        try:
            _, b = call("GET", f"{S}/api/v1/checkout/{saga_id}", token=token, timeout=5)
        except (ConnectionError, TimeoutError, urllib.error.URLError):  # the saga may be restarting (scenario 6)
            failed += 1
            time.sleep(0.5)
            continue
        if b.get("status") in statuses:
            return b
        time.sleep(0.5)
    # One last look: on an overloaded machine this process itself can stall past the deadline, and the
    # last status it saw may be minutes old.
    try:
        _, b = call("GET", f"{S}/api/v1/checkout/{saga_id}", token=token, timeout=10)
        if b.get("status") in statuses:
            return b
    except (ConnectionError, TimeoutError, urllib.error.URLError):
        failed += 1
    # A stale "last" is suspicious when polls failed: say so instead of blaming the saga.
    raise AssertionError(f"saga {saga_id} did not reach {statuses}; last seen: {b.get('status')}; {failed} status polls failed or timed out")


def stock(admin, sku):
    _, b = call("GET", f"{I}/api/v1/inventory/{sku}", token=admin)
    return b["onHand"], b["reserved"]


def order_status(token, order_id):
    return call("GET", f"{O}/api/v1/orders/{order_id}", token=token)[1]["order"]["status"]


def payment_of(admin, customer_id, order_id):
    _, b = call("GET", f"{P}/api/v1/admin/payments?customerId={customer_id}&limit=100", token=admin)
    return next(p for p in b["data"] if p["orderId"] == order_id)


def wait_payment(admin, customer_id, order_id, statuses, timeout=30):
    deadline = time.time() + timeout
    p = {}
    while time.time() < deadline:
        p = payment_of(admin, customer_id, order_id)
        if p["status"] in statuses:
            return p
        time.sleep(0.5)
    raise AssertionError(f"payment for {order_id} did not reach {statuses}; last: {p}")


def click(checkout_url, outcome):
    """What the customer does on the provider's hosted page."""
    s, _ = call("GET", checkout_url)
    assert s == 200, s
    req = urllib.request.Request(f"{checkout_url}/complete", method="POST", data=urllib.parse.urlencode({"outcome": outcome}).encode())
    req.add_header("content-type", "application/x-www-form-urlencoded")
    try:
        opener.open(req, timeout=20)
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("location")
    raise AssertionError("expected a redirect back to the shop")


results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(f"{'✓' if cond else '✗'} {name}{f'  ({detail})' if detail else ''}")


ADDRESS = {"name": "Saga Buyer", "line1": "1 Saga St", "city": "Pune", "postalCode": "411001", "country": "IN", "phone": "+919800000003"}


def checkout(token, sku, qty):
    s, b = call("POST", f"{S}/api/v1/checkout", {"currency": "INR", "items": [{"sku": sku, "quantity": qty}], "shippingAddress": ADDRESS}, token, str(uuid.uuid4()))
    assert s == 202, (s, b)
    return b


def main():
    admin, _ = login("admin@shop.local", ADMIN_PASSWORD)
    email = f"saga-{int(time.time())}@example.com"
    call("POST", f"{A}/api/v1/auth/register", {"email": email, "password": "a long buyer passphrase", "fullName": "Saga Buyer"})
    customer, customer_id = login(email, "a long buyer passphrase")
    sku = "TEE-CLASSIC-WHT-S"
    call("PATCH", f"{I}/api/v1/inventory/{sku}", {"delta": 6, "reason": "RESTOCK", "note": "saga e2e"}, admin, str(uuid.uuid4()))

    # 1. Happy path ------------------------------------------------------------------------------
    on_hand0, _ = stock(admin, sku)
    t0 = time.time()
    c = checkout(customer, sku, 1)
    w = wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT", "CANCELLED", "FAILED"})
    took = time.time() - t0
    check("1a. checkout → order priced, stock reserved, real payment intent → AWAITING_PAYMENT",
          w["status"] == "AWAITING_PAYMENT" and w["checkoutUrl"].startswith(f"{P}/mock-provider/checkout/"), f"{took:.1f}s, {w['checkoutUrl']}")
    p = payment_of(admin, customer_id, w["orderId"])
    _, order = call("GET", f"{O}/api/v1/orders/{w['orderId']}", token=customer)
    check("1b. payment amount = the order's grand total (from the Order Service, not the caller)",
          p["amount"] == order["order"]["totals"]["grandTotal"] and p["status"] == "PENDING", str(p["amount"]))
    status, location = click(w["checkoutUrl"], "pay")
    done = wait_for(customer, c["sagaId"], {"COMPLETED", "CANCELLED", "UNDER_REVIEW"})
    on_hand1, reserved1 = stock(admin, sku)
    check("1c. Pay on the hosted page → signed webhook → PaymentSucceeded → stock confirmed → order CONFIRMED → COMPLETED",
          status == 303 and "result=success" in location and done["status"] == "COMPLETED"
          and order_status(customer, w["orderId"]) == "CONFIRMED" and on_hand1 == on_hand0 - 1 and reserved1 == 0
          and payment_of(admin, customer_id, w["orderId"])["status"] == "SUCCEEDED", f"on hand {on_hand0}→{on_hand1}")

    # 2. Admin refund of the completed order: pending until the provider's webhook confirms -------
    s, b = call("POST", f"{P}/api/v1/payments/{p['id']}/refund", {"reason": "CUSTOMER_REQUESTED"}, admin, str(uuid.uuid4()))
    refunded = wait_payment(admin, customer_id, w["orderId"], {"REFUNDED"})
    check("2. admin refund → 202 PENDING → provider webhook → REFUNDED", s == 202 and b["refund"]["status"] == "PENDING" and refunded["refunded"] == refunded["amount"])

    # 3. Out of stock -----------------------------------------------------------------------------
    c = checkout(customer, sku, 999)
    f = wait_for(customer, c["sagaId"], {"CANCELLED", "FAILED", "COMPLETED"})
    check("3. out of stock → order cancelled → saga CANCELLED (no payment created)",
          f["status"] == "CANCELLED" and f["failureReason"] == "INSUFFICIENT_STOCK" and order_status(customer, f["orderId"]) == "CANCELLED", f["failureReason"])

    # 4. Payment declined -------------------------------------------------------------------------
    before = stock(admin, sku)
    c = checkout(customer, sku, 2)
    w = wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT"})
    click(w["checkoutUrl"], "decline")
    f = wait_for(customer, c["sagaId"], {"CANCELLED", "UNDER_REVIEW"})
    check("4. Decline → PaymentFailed → stock released AND order cancelled → CANCELLED",
          f["status"] == "CANCELLED" and stock(admin, sku) == before and order_status(customer, w["orderId"]) == "CANCELLED"
          and payment_of(admin, customer_id, w["orderId"])["status"] == "FAILED", f"stock back to {before}")

    # 5. No payment in time, then the customer pays anyway (SAGA_PAYMENT_TIMEOUT_SECONDS=15) ------
    c = checkout(customer, sku, 1)
    w = wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT"})
    f = wait_for(customer, c["sagaId"], {"CANCELLED", "UNDER_REVIEW"}, timeout=90)
    check("5a. no payment → timeout → compensation → CANCELLED (PAYMENT_TIMEOUT)",
          f["status"] == "CANCELLED" and f["failureReason"] == "PAYMENT_TIMEOUT" and stock(admin, sku) == before, f["failureReason"])
    click(w["checkoutUrl"], "pay")  # the session was still open at the provider
    late = wait_payment(admin, customer_id, w["orderId"], {"REFUNDED"})
    check("5b. late payment after cancellation → saga sends RefundRequested → refunded automatically",
          late["status"] == "REFUNDED" and order_status(customer, w["orderId"]) == "CANCELLED")

    # 6. Saga crashes while the payment event arrives ---------------------------------------------
    c = checkout(customer, sku, 1)
    w = wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT"})
    subprocess.run(["docker", "compose", "--profile", "apps", "kill", "-s", "SIGKILL", "saga-orchestrator"], cwd=COMPOSE_DIR, check=True, capture_output=True)
    click(w["checkoutUrl"], "pay")  # PaymentSucceeded waits in saga-inbox
    time.sleep(2)
    # `start`, not `up`: restart the same container without re-running its one-off dependency jobs.
    subprocess.run(["docker", "compose", "--profile", "apps", "start", "saga-orchestrator"], cwd=COMPOSE_DIR, check=True, capture_output=True)
    done = wait_for(customer, c["sagaId"], {"COMPLETED", "CANCELLED", "UNDER_REVIEW"})
    order_now = order_status(customer, w["orderId"])
    check("6. saga SIGKILLed while the payment arrives → restarted → resumes from saga-inbox → COMPLETED",
          done["status"] == "COMPLETED" and order_now == "CONFIRMED", f"saga {done['status']}, order {order_now}")

    # 7. Forged webhook ---------------------------------------------------------------------------
    raw = json.dumps({"id": "evt_forged", "type": "checkout.session.completed", "data": {"sessionId": "x", "paymentRef": "p", "amountMinor": "1"}}).encode()
    t = str(int(time.time()))
    forged = "t=" + t + ",v1=" + hmac.new(b"not-the-real-secret", t.encode() + b"." + raw, hashlib.sha256).hexdigest()
    s, b = call("POST", f"{P}/api/v1/payments/webhooks/mock", raw=raw, headers={"x-mock-signature": forged})
    check("7. webhook with a wrong signature → 400 INVALID_SIGNATURE", s == 400 and b.get("code") == "INVALID_SIGNATURE")

    # Nothing dead-lettered -----------------------------------------------------------------------
    dlq = {}
    for q in ("saga-inbox-dlq", "inventory-commands-dlq", "order-commands-dlq.fifo", "payment-commands-dlq"):
        out = subprocess.run(["aws", "--endpoint-url", "http://localhost:4566", "sqs", "get-queue-attributes", "--queue-url",
                              f"http://localhost:4566/000000000000/local-ecommerce-{q}", "--attribute-names", "ApproximateNumberOfMessages", "--output", "json"],
                             check=True, capture_output=True, text=True).stdout
        dlq[q] = json.loads(out)["Attributes"]["ApproximateNumberOfMessages"]
    check("8. all DLQs empty", all(v == "0" for v in dlq.values()), str(dlq))

    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
