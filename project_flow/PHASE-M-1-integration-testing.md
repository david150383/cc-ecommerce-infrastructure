# Phase M-1: Integration Testing: Coverage, Gaps, and How to Test the Hard Things

## 1. Layer by layer

### Unit tests (pure logic)
- **Best example:** [saga decide.test.ts](ecommerce-saga-orchestrator/tests/decide.test.ts), with ~25 cases over the pure
  `decide()` function: happy path, every compensation, late payment, timeouts with the same idempotency keys, manual review,
  stable keys per step. **Mocks nothing**, because `decide` has no I/O. This is why the saga's correctness is so testable.
- Others: Order pricing/state machine, Payment signature (`sign`/`verify`), Notification backoff and templates, Auth password
  policy.
- **Doesn't verify:** that the persistence and publishing of a decision are correct (integration's job).

### Service integration tests (real DB engine + Floci)
- Every DB-owning service recreates its test DB and applies the **real migrations** (global setups), then exercises HTTP
  routes (`supertest` / FastAPI `TestClient`) and messaging against Floci with per-run prefixes.
- Highlights worth knowing:
  - Inventory: **concurrent reservations never oversell** (checklist CLAIM), schema-valid events for a full cycle,
    DLQ for invalid commands.
  - Saga [saga-flows.test.ts](ecommerce-saga-orchestrator/tests/saga-flows.test.ts): crash between creating the order and
    recording it; a lease expiring; two instances processing the same overdue sagas; concurrent conflicting events; the
    checkout limit under concurrency.
  - Saga [messaging.test.ts](ecommerce-saga-orchestrator/tests/messaging.test.ts): two relays racing keep per-saga order; startup
    drain prevents a paid checkout being cancelled by a timeout.
  - Payment: forged, tampered, replayed and duplicate webhooks; refunds bounded; reconciliation.
  - Notification: retries with backoff; secret-bearing mail never stored or logged.
- **Mocks:** downstream HTTP services (stubs in client tests), the payment provider (mock, or Stripe adapter offline),
  SMTP (fake). **Doesn't verify:** real AWS (IAM, KMS, FIFO throughput), cross-service HTTP shapes (L-F3).

### Contract tests
See Phase L (L-1 §5–6, L-2 §3). The gap is backend-to-backend HTTP.

### Cross-service scripts and Playwright
See M-0 §2. These are the only tests that exercise **the whole saga through real services**.

## 2. What's missing, judged for this platform (not a generic wish list)

| Missing test | Why it matters **here** | Suggested shape |
|---|---|---|
| **Cross-service tests in CI** | They exist but only run by hand. The nightly workflow can't run (repo names, private clones, contracts remote) | Fix e2e.yml (J-F5/J-F12). Until then, run them before merging `phase7` |
| **Outbox poison-row isolation** | P1-2: one bad row stalls every saga | saga integration test: one row to a nonexistent queue + a valid row of another saga, then assert the valid one is published |
| **Pay-and-cancel race** | P2-3 ends in MANUAL_REVIEW, untested | decide test: `AWAITING_PAYMENT` → `PaymentSucceeded` → `OrderCancelled` in `CONFIRMING_*`; plus a scripted race in verify-checkout-saga |
| **Migration compatibility (old code + new schema)** | Rolling deploys run the previous release against the migrated schema | In CI: check out the previous tag's code, run the new migrations, run the old test suite (or a smoke subset) against it |
| **System-level load / concurrency** | Connection budget (K-F6), saga throughput, FIFO group behavior, WAF limits vs CGNAT | k6/Gatling against staging: N concurrent checkouts on few SKUs; watch DB connections, saga deadlines, DLQs |
| **Chaos on messaging** | Floci or SQS unavailable; SNS throttling | stop Floci mid-checkout in the scripts; assert outbox rows accumulate and drain after recovery |
| **IAM / real-AWS smoke** | K-F2, K-F3: emulator can't catch them | after the first dev apply: `simulate-principal-policy` checks + a synthetic checkout in dev |
| **Backend HTTP contract tests** | L-F3 | vendored callee OpenAPI + response validation in client tests |
| **Post-deploy smoke** | The deploy job ends at "rollout COMPLETED". Healthy ≠ working | a job after each environment: `GET /api/v1/products` via the shop origin + a synthetic login; block promotion on failure |

## 3. How to test the hard things (designs grounded in this code)

### Concurrency (no oversell)
Fire N concurrent `POST /api/v1/inventory/reservations` (or `InventoryReservationRequested` commands) for the same SKU
with stock < N, then assert: the reserved total ≤ on-hand, the CHECK `reserved <= on_hand` never fired, exactly `stock` successes,
and the rest `INSUFFICIENT_STOCK`. Why it holds: the single conditional `UPDATE … WHERE on_hand - reserved >= $2`
([reservation.service.ts:112-115](ecommerce-inventory-service/src/inventory/reservation.service.ts#L112-L115)). A test that
used SELECT-then-UPDATE would *fail* this, which is the point of the test.

### Duplicate messages
Send the **same envelope twice** (same `messageId`) and a **re-emitted answer** (new `messageId`, same content). Assert
one state change and one outbox row per decision. Saga examples exist ("a redelivered event (same messageId) is dropped…",
"a duplicate answer with a NEW messageId … is ignored by state"). For commands: send `RefundRequested` twice with the
same `idempotencyKey`, then assert one refund and one provider call (Payment tests).

### Webhook retries
Deliver the same provider event id twice → second `"duplicate"`. Deliver an event for a session not yet stored → 5xx
(the provider retries), then store the session and redeliver → applied. Deliver with a timestamp outside 300 s → 400.
Deliver success for an EXPIRED payment → SUCCEEDED + the saga refunds (money truth wins).

### Saga recovery after a crash
Already scripted: SIGKILL the saga while `PaymentSucceeded` is in flight, restart, assert COMPLETED (verify-checkout-saga
step 6). In tests: set a lease, "kill" by never applying the result, advance the clock past `lease_until`, run
`processDue`, then assert the same idempotency key was used and no duplicate order exists.

### Migration compatibility (expand → contract safety)
1. Apply migrations from the **new** commit to an empty DB.
2. Start the **previous** release's image against it (compose `image:` override), run its smoke (or full) tests.
3. Fail if anything breaks. That means the migration was not backward compatible.

## 4. Test environments and data

| Environment | Data | Who uses it |
|---|---|---|
| Laptop compose | `python -m app.seed` demo catalog; admin via `create-admin.ts`; Mailpit; mock provider | you |
| CI service containers | empty DBs recreated per run | per repo |
| Nightly E2E (designed) | the same as the laptop, built from `main` of all repos | platform |
| AWS dev/staging (designed) | **no seed strategy defined**; Stripe **test mode** keys | future: staging needs representative data volumes for migration and RTO tests |

Never point any `TEST_*_URL` at a shared database: the global setups drop and recreate it.
