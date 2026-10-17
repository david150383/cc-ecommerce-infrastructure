# Phase E: Payment Service and Financial Correctness

Read-only walkthrough of `ecommerce-payment-service` (Express 5 + raw `pg` + Stripe SDK) on `phase7`. Phase A-2 covered
Payment's part in the saga. This phase covers its internals and the money invariants.

---

## 1. Responsibility and the money invariants it protects

Payment owns payment attempts, provider sessions, webhooks, refunds and reconciliation. Every rule below exists to keep
these invariants true:

| # | Invariant | Enforced by |
|---|---|---|
| I1 | The charged amount equals the order's authoritative total | amount read from Order (`GET /internal/v1/orders/{id}`), never from the caller; `CHECK amount_minor > 0` |
| I2 | At most one payment per order | `UNIQUE (order_id)` |
| I3 | A retried "create payment" never creates a second payment or provider session | `UNIQUE (idempotency_key)` + provider idempotency key `checkout:{paymentId}` |
| I4 | Only the provider can declare a payment succeeded | signed webhook (or server-side status query in reconciliation); the browser redirect proves nothing |
| I5 | Each provider event is applied at most once | `UNIQUE (provider, provider_event_id)` in `webhook_events`, inserted **in the same transaction** as the state change |
| I6 | Money taken is never kept without an order | "money truth wins": success is recorded even for FAILED/EXPIRED payments, and the saga refunds |
| I7 | Refunds never exceed what was paid | refundable = paid − refunded − **pending**; `CHECK refunded_minor <= amount_minor` |
| I8 | A refund is never sent twice | `UNIQUE (idempotency_key)` on refunds + provider key `refund:{refundId}` |
| I9 | A refund is complete only when the provider confirms | `PENDING` until webhook/reconciliation; `RefundSucceeded` only then |

## 2. The provider boundary ([provider.ts](ecommerce-payment-service/src/providers/provider.ts))

`PaymentProvider` = `createCheckout`, `parseWebhook` (verify + **normalize** into `ProviderEvent`), `getPaymentState`,
`refund`, `getRefundState`. Everything Stripe-specific stays behind it. That's the **adapter / ports-and-adapters**
pattern: the business logic ([payment-service.ts](ecommerce-payment-service/src/payments/payment-service.ts)) never sees
Stripe event names. Adding Razorpay means one new adapter.

### Stripe adapter ([stripe-provider.ts](ecommerce-payment-service/src/providers/stripe-provider.ts))
- API version **pinned** (`2026-09-30.endive`), `maxNetworkRetries: 2`, `timeout: 10 s`.
- `checkout.sessions.create`: one line item with **our** amount, `client_reference_id` + metadata = paymentId/orderId,
  `success_url`/`cancel_url` from the saga's return URL, `expires_at` from our expiry (Stripe allows 30 min–24 h, so
  `CHECKOUT_EXPIRY_MINUTES` has `min(30)`), and Stripe's own idempotency key.
- Webhook mapping:
  - `checkout.session.completed` **with `payment_status = paid`** → succeeded. **Unpaid** completions (delayed methods)
    are ignored until `async_payment_succeeded`. This is a classic bug that's avoided here.
  - `async_payment_failed` → failed.
  - `expired` → session expired.
  - `refund.updated/failed` → refund outcome. Our `refundId` is echoed in metadata, so a webhook that arrives **before**
    we stored Stripe's refund id still finds its row.
- `constructEvent(rawBody, header, secret, 300)` verifies the signature with a 5-minute tolerance.

### Mock adapter ([mock-provider.ts](ecommerce-payment-service/src/providers/mock-provider.ts), [mock-routes.ts](ecommerce-payment-service/src/providers/mock-routes.ts))
It's faithful where it matters: a hosted page with Pay/Decline, webhooks **signed with the same scheme as Stripe**
([signature.ts](ecommerce-payment-service/src/providers/signature.ts): HMAC-SHA256 over `t.rawBody`, timestamp
tolerance, constant-time compare) and **delivered over HTTP to the service itself**. Refunds are pending first and
confirmed later. So locally the **real** verification and dedupe code runs. Safety: the config refuses `mock` when
`NODE_ENV=production`, and the ALB blocks `/mock-provider/*`. State is in memory: a restart forgets sessions, and
reconciliation marks them expired after their expiry.

## 3. The flows, line by line

### 3.1 Create intent ([payment-service.ts:103-172](ecommerce-payment-service/src/payments/payment-service.ts#L103-L172))
1. `findByKey(idempotencyKey)`. If found but for another order → 422.
2. Not found: `orders.get(orderId)` (service token) → status must be `INVENTORY_RESERVED | PAYMENT_PENDING` (409 otherwise).
3. TX: `INSERT payments (…, amount from Order, expires_at = now + N min)` + `PaymentInitiated` outbox.
   Unique violations: same key → replay; same order → 409 `PAYMENT_EXISTS`.
4. If there's no provider session yet → `openSession` **outside** any transaction (never hold a DB transaction across a network
   call). Provider failure → 503 (the payment row stays; the retry with the same key completes it).

### 3.2 Webhook ([routes.ts:22-31](ecommerce-payment-service/src/api/routes.ts#L22-L31), [payment-service.ts:216-297](ecommerce-payment-service/src/payments/payment-service.ts#L216-L297))
1. The route is mounted **before** the JSON parser with `express.raw({ type: "*/*", limit: "256kb" })`, because the signature is
   over the exact bytes. `:provider` must equal the configured provider (else 404).
2. `parseWebhook` → bad signature: 400 `INVALID_SIGNATURE` (logged with the reason); unparsable: 400.
3. TX: `INSERT webhook_events … ON CONFLICT DO NOTHING`. 0 rows → `"duplicate"` (200: the provider stops retrying).
4. Apply under `SELECT … FOR UPDATE` of the payment/refund. **Unknown session or refund → throw → 500 → the provider
   retries later** (the webhook may have overtaken our own write). The whole TX, including the dedupe row, rolls back, so
   the retry isn't treated as a duplicate.
5. `applyPaymentOutcome`: the single place payment status changes. Succeeded from `PENDING/FAILED/EXPIRED` (money truth wins);
   failed/expired only from `PENDING`; repeats are no-ops.

### 3.3 Refund ([:305-410](ecommerce-payment-service/src/payments/payment-service.ts#L305-L410))
1. Existing key → return it (no second refund).
2. TX: lock the payment row; compute refundable = amount − refunded − pending; status must be SUCCEEDED/PARTIALLY_REFUNDED.
   Not refundable → insert the refund as **FAILED `NOT_REFUNDABLE`** + `RefundFailed` event (recorded and answered, never dropped).
3. `submitRefund` **outside** the TX: provider call with idempotency key `refund:{refundId}`. Network error → stays
   PENDING without a provider id (reconciliation re-submits with the **same** key, so it's safe).
4. Immediate outcome or a later webhook → `applyRefundOutcome`: SUCCEEDED → `refunded_minor += amount`, status
   PARTIALLY_REFUNDED/REFUNDED, `RefundSucceeded`; FAILED → `RefundFailed`.
5. Duplicate `RefundRequested` command → `reemitRefundOutcome` once the refund is final (the saga isn't left waiting).

### 3.4 Reconciliation ([:419-467](ecommerce-payment-service/src/payments/payment-service.ts#L419-L467), [runner.ts](ecommerce-payment-service/src/messaging/runner.ts))
Every `RECONCILE_INTERVAL_MS` (60 s): payments `PENDING` with a session, older than `RECONCILE_AFTER_SECONDS` (300 s), get a
`getPaymentState` call (pending past expiry → expired). Refunds `PENDING` either get **re-submitted** (no provider id) or have
their state queried. The outcome goes through the **same** `apply*Outcome` functions as webhooks, so there's one code path for state changes.
Batches are 50 each, so a large backlog takes several cycles (fine).

## 4. Failure scenarios, answered from the code

| Scenario | Outcome |
|---|---|
| Customer pays twice (two tabs) | One session per payment (provider idempotency), one payment per order. A second capture would be a provider-side event for the same session: idempotent |
| Webhook lost | Reconciliation after ~5 min queries the provider |
| Webhook before our session id is stored | 500 → provider retries → applied later |
| Webhook replayed by an attacker | signature + 5-min window + dedupe row → 400 or `duplicate` |
| Forged webhook | 400 `INVALID_SIGNATURE` (verify-checkout-saga step 7) |
| Payment succeeds after the saga cancelled | recorded SUCCEEDED; saga → `RefundRequested` (I6) |
| Refund call times out | refund PENDING without a ref → reconciliation re-submits with the same key; the provider dedupes |
| Refund requested for more than is left | `NOT_REFUNDABLE` → `RefundFailed` → saga manual review |
| Captured amount ≠ order total | **only logged** ([:260-262](ecommerce-payment-service/src/payments/payment-service.ts#L260-L262)): N-15 |

## 5. New finding: the admin UI tells operators to refund by hand (CONFIRMED)

[AdminOperations.tsx:203](ecommerce-frontend/src/pages/admin/AdminOperations.tsx#L203), for a `CANCELLATION_PENDING` order:
*"The customer asked to cancel a paid order. Refund it from Payments; this order then needs its status closed by hand (no
automated flow yet)."* That text predates S-11. **The saga now refunds automatically.**

An admin who follows the instruction races the saga:
- If the admin's refund is first (PENDING or SUCCEEDED), the saga's `RefundRequested` finds refundable = 0, so
  `NOT_REFUNDABLE` → `RefundFailed` → the saga goes to **`MANUAL_REVIEW`**, and the order stays `REFUND_PENDING`.
- If the saga's refund is first, the admin's refund fails `NOT_REFUNDABLE`.

**Money stays safe** (I7: no double refund), but the operator is misled, and checkouts end in manual review for no reason.
More generally, an admin refund through `POST /payments/{id}/refund` **bypasses the saga**: the order and stock don't
change, which is correct for a goodwill/partial refund and wrong for a cancellation.

**Fix (low):** change the alert to *"Refund in progress automatically; no action needed unless it lands in Checkouts →
needs review"*. On the payment refund form, warn when the order is `CANCELLATION_PENDING`/`REFUND_PENDING` (or block it).
Document that full refunds of an order go through **order cancellation**, while partial/goodwill refunds go through Payments.
Added to the backlog as **N-33 (P2)**.

## 6. Alternatives and trade-offs
- Hosted checkout (Stripe Checkout, used) vs embedded card fields (Elements) vs a server-side card API: hosted keeps card
  data entirely off our servers (the smallest PCI scope, SAQ A). Elements gives more UI control at slightly larger scope.
- Authorize-then-capture (capture at shipment) vs immediate capture (used): immediate is simpler. Authorize/capture avoids
  refunds when stock fails after payment, at the cost of auth expiry handling (~7 days).
- Webhooks + reconciliation (used) vs polling only vs webhooks only: both together is the robust standard.

## 7. What not to do (and the code avoids it)
Trust a client-supplied amount; trust the success redirect; parse JSON before verifying the signature; acknowledge a
webhook before committing its effect; call the provider inside a DB transaction; retry a refund with a new idempotency key;
log card data (redaction includes `cardNumber`/`cvv`, though card data never arrives here anyway).

## 8. Tests ([tests/](ecommerce-payment-service/tests))
`payments.test.ts` (intent idempotency, amount from Order, webhook verify/dedupe/replay/forged/tampered, money truth wins,
refund bounds, reconciliation, duplicate refund command re-answers), `stripe-provider.test.ts` (adapter offline: signature, unpaid
completion ignored, refund mapping), `messaging.test.ts`, `event-schemas.test.ts`, `openapi.test.ts`.

## Exercises and acceptance criteria (Phase E)
1. For each invariant I1–I9, name the exact line or constraint that enforces it.
2. Explain why the webhook handler throws (500) for an unknown session instead of returning 200.
3. Walk through a refund whose provider call times out, until it's SUCCEEDED, naming every idempotency key involved.
4. Rewrite the admin alert text from §5 and describe the guard you'd add to the refund form.

**You're done with Phase E when** you can defend each money invariant, explain the webhook pipeline (raw body → verify →
dedupe → apply in one TX), and explain why reconciliation reuses the webhook code path.
