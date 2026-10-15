"""End-to-end cancellation of a PAID order through the real services: the customer cancels a CONFIRMED
order, the saga refunds it (mock provider, signed webhook), the order ends REFUNDED and the stock goes
back on hand. Same prerequisites as verify-checkout-saga.py (whose helpers this reuses).

    ADMIN_PASSWORD='…' python3 -u scripts/verify-order-cancellation.py
"""
import importlib.util
import os
import sys
import time
import uuid

spec = importlib.util.spec_from_file_location("saga_e2e", os.path.join(os.path.dirname(__file__), "verify-checkout-saga.py"))
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)
A, I, O, S = e2e.A, e2e.I, e2e.O, e2e.S
call, check, stock, order_status = e2e.call, e2e.check, e2e.stock, e2e.order_status


def wait_until(fn, want, timeout=90):
    """Polls fn() until it returns a value in `want`; returns the last value either way."""
    deadline = time.time() + timeout
    value = None
    while time.time() < deadline:
        try:
            value = fn()
        except (ConnectionError, TimeoutError, OSError):
            value = None
        if value in want:
            return value
        time.sleep(0.5)
    return fn()  # one last look (this process itself may have stalled past the deadline)


def main():
    admin, _ = e2e.login("admin@shop.local", e2e.ADMIN_PASSWORD)
    email = f"cancel-{int(time.time())}@example.com"
    call("POST", f"{A}/api/v1/auth/register", {"email": email, "password": "a long buyer passphrase", "fullName": "Cancel Buyer"})
    customer, customer_id = e2e.login(email, "a long buyer passphrase")
    sku = "TEE-CLASSIC-WHT-S"
    call("PATCH", f"{I}/api/v1/inventory/{sku}", {"delta": 3, "reason": "RESTOCK", "note": "cancellation e2e"}, admin, str(uuid.uuid4()))

    # A completed, paid order.
    on_hand0, _ = stock(admin, sku)
    c = e2e.checkout(customer, sku, 2)
    w = e2e.wait_for(customer, c["sagaId"], {"AWAITING_PAYMENT", "CANCELLED", "FAILED"})
    e2e.click(w["checkoutUrl"], "pay")
    done = e2e.wait_for(customer, c["sagaId"], {"COMPLETED", "CANCELLED", "UNDER_REVIEW"})
    order_id = w["orderId"]
    on_hand1, _ = stock(admin, sku)
    check("1. paid order: COMPLETED, CONFIRMED, 2 units left the shelf",
          done["status"] == "COMPLETED" and order_status(customer, order_id) == "CONFIRMED" and on_hand1 == on_hand0 - 2, f"on hand {on_hand0}→{on_hand1}")

    # Someone else cannot cancel it.
    other_email = f"other-{int(time.time())}@example.com"
    call("POST", f"{A}/api/v1/auth/register", {"email": other_email, "password": "a long buyer passphrase", "fullName": "Other"})
    other, _ = e2e.login(other_email, "a long buyer passphrase")
    s, _ = call("POST", f"{O}/api/v1/orders/{order_id}/cancel", token=other)
    check("2. another customer cannot cancel it (404, not 403: its existence is not revealed)", s == 404, str(s))

    # The customer cancels (twice: a double click changes nothing).
    s1, b1 = call("POST", f"{O}/api/v1/orders/{order_id}/cancel", token=customer)
    s2, b2 = call("POST", f"{O}/api/v1/orders/{order_id}/cancel", token=customer)
    check("3. cancel → CANCELLATION_PENDING (a refund is needed); repeat is idempotent",
          s1 == 200 and b1["order"]["status"] == "CANCELLATION_PENDING" and s2 == 200 and b2["order"]["status"] in {"CANCELLATION_PENDING", "REFUND_PENDING", "REFUNDED"},
          f"{b1['order']['status']} / {b2['order']['status']}")

    final = wait_until(lambda: order_status(customer, order_id), {"REFUNDED"})
    payment = e2e.wait_payment(admin, customer_id, order_id, {"REFUNDED"}, timeout=60)
    check("4. saga: REFUND_PENDING → RefundRequested (full total) → provider webhook → order REFUNDED",
          final == "REFUNDED" and payment["refunded"] == payment["amount"], f"order {final}, refunded {payment['refunded']} of {payment['amount']}")

    on_hand2 = wait_until(lambda: stock(admin, sku)[0], {on_hand0})
    check("5. InventoryReturnRequested → the 2 units are back on hand, nothing left reserved",
          on_hand2 == on_hand0 and stock(admin, sku)[1] == 0, f"on hand {on_hand1}→{on_hand2}")

    saga = e2e.wait_for(customer, c["sagaId"], {"CANCELLED", "UNDER_REVIEW"})
    _, order = call("GET", f"{O}/api/v1/orders/{order_id}", token=customer)
    history = [h["to"] for h in order["order"]["statusHistory"]]
    check("6. saga CANCELLED; order history ends CONFIRMED → CANCELLATION_PENDING → REFUND_PENDING → REFUNDED",
          saga["status"] == "CANCELLED" and history[-4:] == ["CONFIRMED", "CANCELLATION_PENDING", "REFUND_PENDING", "REFUNDED"], " → ".join(history[-4:]))

    s, b = call("POST", f"{O}/api/v1/orders/{order_id}/cancel", token=customer)
    check("7. a refunded order cannot be cancelled again (409 CANNOT_CANCEL)", s == 409 and b.get("code") == "CANNOT_CANCEL", str(s))

    sys.exit(0 if all(e2e.results) else 1)


if __name__ == "__main__":
    main()
