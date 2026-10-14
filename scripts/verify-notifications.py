"""End-to-end notifications through the REAL services (Phase 4b): Auth → Notification Service (secret-bearing
mail over internal REST), events over Floci SNS/SQS → Notification Service → Mailpit (SMTP) and the console SMS
adapter.

Prerequisites (see docs/architecture/local-development.md):
  NOTIFICATION_RETRY_BASE_MS=2000 docker compose --profile apps up -d --no-build --no-deps notification-service
  demo catalog seeded; admin@shop.local exists (password via ADMIN_PASSWORD below)
    ADMIN_PASSWORD='…' python3 -u scripts/verify-notifications.py
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

A, I, N, P, S, MAILPIT = "http://localhost:4001", "http://localhost:4003", "http://localhost:4006", "http://localhost:4005", "http://localhost:4007", "http://localhost:8025"
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "shop owner passphrase 2026")
os.environ.update(AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="test", AWS_DEFAULT_REGION="us-east-1")
COMPOSE_DIR = os.path.join(os.path.dirname(__file__), "..")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)


def call(method, url, body=None, token=None, key=None, form=None):
    data = urllib.parse.urlencode(form).encode() if form else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("content-type", "application/x-www-form-urlencoded" if form else "application/json")
    if token:
        req.add_header("authorization", f"Bearer {token}")
    if key:
        req.add_header("idempotency-key", key)
    try:
        with opener.open(req, timeout=20) as r:
            text = r.read()
            return r.status, (json.loads(text) if text and r.headers.get_content_type() == "application/json" else {})
    except urllib.error.HTTPError as e:
        text = e.read()
        try:
            return e.code, json.loads(text or b"{}")
        except ValueError:
            return e.code, {}


def login(email, password):
    s, b = call("POST", f"{A}/api/v1/auth/login", {"email": email, "password": password})
    assert s == 200, (s, b)
    return b["accessToken"], b["user"]["id"]


def until(fn, timeout=40, what="condition"):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            v = fn()
        except (ConnectionError, urllib.error.URLError):  # e.g. Mailpit restarting in scenario 5
            v = None
        if v:
            return v
        time.sleep(0.5)
    raise AssertionError(f"timed out waiting for {what}")


def mails_to(address):
    q = urllib.parse.quote(f'to:"{address}"')
    with urllib.request.urlopen(f"{MAILPIT}/api/v1/search?query={q}&limit=50", timeout=10) as r:
        return json.loads(r.read())["messages"]


def mail_text(message_id):
    with urllib.request.urlopen(f"{MAILPIT}/api/v1/message/{message_id}", timeout=10) as r:
        return json.loads(r.read())["Text"]


def wait_mail(address, subject_part, timeout=40):
    return until(lambda: next((m for m in mails_to(address) if subject_part in m["Subject"]), None), timeout, f"'{subject_part}' to {address}")


def psql(db, user, sql):
    return subprocess.run(["docker", "compose", "exec", "-T", "postgres", "psql", "-U", user, "-d", db, "-Atc", sql],
                          cwd=COMPOSE_DIR, check=True, capture_output=True, text=True).stdout.strip()


def compose(*args):
    subprocess.run(["docker", "compose", "--profile", "apps", *args], cwd=COMPOSE_DIR, check=True, capture_output=True)


results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(f"{'✓' if cond else '✗'} {name}{f'  ({detail})' if detail else ''}")


ADDRESS = {"name": "Notify Buyer", "line1": "1 Mail St", "city": "Pune", "postalCode": "411001", "country": "IN", "phone": "+919800000004"}


def buy(token, sku, qty=1):
    s, c = call("POST", f"{S}/api/v1/checkout", {"currency": "INR", "items": [{"sku": sku, "quantity": qty}], "shippingAddress": ADDRESS}, token, str(uuid.uuid4()))
    assert s == 202, (s, c)
    w = until(lambda: (lambda b: b if b.get("status") in ("AWAITING_PAYMENT", "CANCELLED") else None)(call("GET", f"{S}/api/v1/checkout/{c['sagaId']}", token=token)[1]), what="AWAITING_PAYMENT")
    assert w["status"] == "AWAITING_PAYMENT", w
    status, _ = call("POST", f"{w['checkoutUrl']}/complete", form={"outcome": "pay"})
    assert status == 303, status
    until(lambda: call("GET", f"{S}/api/v1/checkout/{c['sagaId']}", token=token)[1].get("status") == "COMPLETED", what="COMPLETED")
    return w["orderId"]


def main():
    admin, _ = login("admin@shop.local", ADMIN_PASSWORD)
    email = f"notify-{int(time.time())}@example.com"
    s, _ = call("POST", f"{A}/api/v1/auth/register", {"email": email, "password": "a long buyer passphrase", "fullName": "Nia Buyer"})
    assert s in (200, 201), s

    # 1. Secret-bearing mail via the internal REST endpoint ---------------------------------------
    verify = wait_mail(email, "Verify your email")
    token = re.search(r"token=([\w%-]+)", mail_text(verify["ID"])).group(1)
    stored = psql("notification_db", "notification_svc", "SELECT coalesce(string_agg(t::text, ''), '') FROM (SELECT n::text AS t FROM notifications n UNION ALL SELECT d::text FROM delivery_attempts d) x")
    check("1a. register → verification email (Auth → Notification internal endpoint → Mailpit)", verify is not None)
    check("1b. the verification token is in the email but nowhere in notification_db", token and urllib.parse.unquote(token) not in stored and token not in stored)
    s, _ = call("POST", f"{A}/api/v1/auth/verify-email", {"token": urllib.parse.unquote(token)})
    check("1c. the emailed link works (email verified)", s in (200, 204), f"HTTP {s}")

    # 2. Welcome email from the UserRegistered event (SNS → notification-inbox) -------------------
    welcome = wait_mail(email, "Welcome")
    check("2. UserRegistered → recipient directory + welcome email", "Nia Buyer" in mail_text(welcome["ID"]))

    # 3. Password reset end to end ----------------------------------------------------------------
    call("POST", f"{A}/api/v1/auth/forgot-password", {"email": email})
    reset = wait_mail(email, "Reset your password")
    reset_token = urllib.parse.unquote(re.search(r"token=([\w%-]+)", mail_text(reset["ID"])).group(1))
    s, _ = call("POST", f"{A}/api/v1/auth/reset-password", {"token": reset_token, "newPassword": "a brand new passphrase 2026"})
    customer, customer_id = login(email, "a brand new passphrase 2026")
    check("3. forgot-password → reset email → link resets the password → login with the new one", s in (200, 204), f"HTTP {s}")

    # 4. Order confirmation + SMS opt-in ----------------------------------------------------------
    s, _ = call("PUT", f"{N}/api/v1/notifications/preferences",
                {"email": {"orderUpdates": True, "marketing": False}, "sms": {"orderUpdates": True, "phone": "+919800000004"}}, customer)
    sku = "TEE-CLASSIC-WHT-S"
    call("PATCH", f"{I}/api/v1/inventory/{sku}", {"delta": 5, "reason": "RESTOCK", "note": "notify e2e"}, admin, str(uuid.uuid4()))
    order_id = buy(customer, sku)
    confirmed = wait_mail(email, "confirmed")
    _, history = call("GET", f"{N}/api/v1/notifications/history", token=customer)
    sms = [h for h in history["data"] if h["templateKey"] == "order.confirmed" and h["channel"] == "sms"]
    check("4a. OrderConfirmed → order confirmation email with the total", "₹" in mail_text(confirmed["ID"]) and order_id[-8:].upper() in confirmed["Subject"])
    check("4b. opted in with a phone → the SMS went out too (console adapter)", s == 200 and sms and sms[0]["status"] == "SENT", sms[0]["status"] if sms else "none")

    # 5. Mail server down → retries with backoff → delivered after it comes back -----------------
    compose("stop", "mailpit")
    try:
        order2 = buy(customer, sku)
        row = until(lambda: psql("notification_db", "notification_svc",
                                 f"SELECT status || ' ' || attempts FROM notifications WHERE template_key = 'order.confirmed' AND channel = 'email' AND data->>'orderId' = '{order2}' AND attempts >= 1 AND status = 'QUEUED'"),
                    what="a failed attempt")
    finally:
        compose("start", "mailpit")
    until(lambda: call("GET", f"{MAILPIT}/api/v1/info")[0] == 200, what="mailpit up")
    late = wait_mail(email, order2[-8:].upper(), timeout=60)
    attempts = psql("notification_db", "notification_svc", f"SELECT attempts FROM notifications WHERE template_key = 'order.confirmed' AND channel = 'email' AND data->>'orderId' = '{order2}'")
    check("5. SMTP down → QUEUED with backoff → Mailpit back → delivered", late is not None, f"while down: {row}; delivered after {attempts} attempts")

    # 6. Low stock → admin alert ------------------------------------------------------------------
    _, item = call("GET", f"{I}/api/v1/inventory/{sku}", token=admin)
    available = item["onHand"] - item["reserved"]
    s, _ = call("PATCH", f"{I}/api/v1/inventory/{sku}", {"lowStockThreshold": available - 1}, admin, str(uuid.uuid4()))
    assert s == 200, f"setting the threshold failed: HTTP {s}"
    buy(customer, sku)
    alert = wait_mail("ops@shop.local", f"Low stock: {sku}")
    check("6. a reservation crosses the threshold → InventoryLowStock → admin alert email", s == 200 and alert is not None, f"threshold {available - 1}")
    call("PATCH", f"{I}/api/v1/inventory/{sku}", {"lowStockThreshold": 5}, admin, str(uuid.uuid4()))

    # 7. Dead letters -----------------------------------------------------------------------------
    _, dl = call("GET", f"{N}/api/v1/admin/notifications/dead-letters", token=admin)
    check("7. notification DLQs empty (admin API)", dl.get("depths") and all(v == 0 for v in dl["depths"].values()), str(dl.get("depths")))

    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
