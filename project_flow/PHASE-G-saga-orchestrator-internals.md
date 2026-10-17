# Phase G: Saga Orchestrator: API, Concurrency Model, Workers, Recovery, Operations

Phase A-2 is the companion to this file: the **state machine**, the happy path, and every failure/compensation row are
there. Phase G covers how the saga **runs**: its HTTP API, how it stays correct with several instances running, how its
background loops start and stop, and how operators work with it. Read-only, `phase7`.

---

## 1. HTTP API ([routes.ts](ecommerce-saga-orchestrator/src/api/routes.ts), [schemas.ts](ecommerce-saga-orchestrator/src/api/schemas.ts))

| Endpoint | Role | Behavior |
|---|---|---|
| `POST /api/v1/checkout` | customer, admin | body: `items` (1–100, quantity 1–1000, **unique SKUs**), `currency`, `shippingAddress`, optional `couponCode`. **No prices** ("Prices and totals are never accepted from the browser"). `Idempotency-Key` required. Always **202** + `Location: statusUrl` (the work continues asynchronously); a replay adds `Idempotency-Replayed: true`. Errors: 422 key reuse with a different body, **429 `TOO_MANY_ACTIVE_CHECKOUTS`** |
| `GET /api/v1/checkout/{sagaId}` | owner or admin | `toCheckoutStatus`: customer-facing status (6 values, A-2 §1), `orderId`, `checkoutUrl` **only while AWAITING_PAYMENT**, failure reason. Someone else's saga → 404 |
| `GET /api/v1/admin/sagas` | admin | filter by state, keyset pagination (UUIDv7 id) |
| `GET /api/v1/admin/sagas/{id}` | admin | the saga + full `saga_steps` history |
| `POST /api/v1/admin/sagas/{id}/retry` | admin | `deadline_at = now(), lease_until = NULL` for non-terminal, non-review sagas: the timer picks it up |
| `POST /api/v1/admin/sagas/{id}/resolve` | admin | only `MANUAL_REVIEW` → `RESOLVED`, with `"<adminId>: <resolution>"` recorded in the step trigger |

**202 + polling** is the contract: the browser polls `statusUrl` until `AWAITING_PAYMENT` (then redirects to `checkoutUrl`)
or a final state. Starting a checkout runs the first synchronous step (create order) **inline** after persisting STARTED, so
the first poll usually already shows progress.

## 2. Concurrency model: seven mechanisms, each for one race

| Mechanism | Code | Prevents |
|---|---|---|
| **Unique `(customer_id, idempotency_key)`** + replay check | [repository.ts:80-115](ecommerce-saga-orchestrator/src/saga/repository.ts#L80-L115) | two sagas for one double-clicked checkout |
| **`pg_advisory_xact_lock(hashtextextended('checkout:'||customerId))`** | same, line 85 | two parallel requests both passing "fewer than 3 active checkouts" (count-then-insert race); the lock is released at commit |
| **Row lock `SELECT … FOR UPDATE`** on `saga_instances` in every event/timeout/operator transaction | `lock()`, `lockByOrder()` | two events for one saga applied concurrently (e.g. PaymentSucceeded vs a timeout) |
| **`processed_messages` insert in the same TX** | `markProcessed()` | the same event applied twice |
| **Lease (`lease_until`) for synchronous steps** + **version check** after the HTTP call | [engine.ts:120-138](ecommerce-saga-orchestrator/src/saga/engine.ts#L120-L138), `lease()` | two instances calling Order/Payment for the same saga; applying a stale HTTP result after the saga moved on |
| **`FOR UPDATE SKIP LOCKED`** in `claimDue` (+ a re-check under the row lock in `processOne`) | [repository.ts:202-213](ecommerce-saga-orchestrator/src/saga/repository.ts#L202-L213), [engine.ts:185-198](ecommerce-saga-orchestrator/src/saga/engine.ts#L185-L198) | two timer loops handling the same overdue saga |
| **Outbox head-of-line per saga** (`NOT EXISTS older unpublished of the same saga`) + `SKIP LOCKED` | [outbox-relay.ts:64-74](ecommerce-saga-orchestrator/src/messaging/outbox-relay.ts#L64-L74) | two relays sending one saga's FIFO commands out of order |

The rule behind them: **no network call inside a transaction, and no transaction-less state change.** HTTP calls happen
between two short transactions (lease → call → re-lock, check version, apply), and the result is discarded if anything changed meanwhile.

Scaling out: all of the above make **N saga instances safe**. Throughput is bounded by the per-saga serialization (fine)
and by the single outbox relay order rule (fine at this scale, but see N-02 for the failure isolation gap).

## 3. Workers lifecycle ([runner.ts](ecommerce-saga-orchestrator/src/messaging/runner.ts), [server.ts](ecommerce-saga-orchestrator/src/server.ts))

```
server.listen → workers.start():
  relay.start()                         # publishes committed outbox rows every OUTBOX_POLL_INTERVAL_MS
  draining = true; timer tick()         # timer runs, but ONLY sync-step retries (timeouts: false)
  inbox.drain(STARTUP_DRAIN_MS=65 s)    # apply events that arrived while we were down, BEFORE judging deadlines
  draining = false                      # from now on the timer also judges timeouts
  inbox.start()                         # normal long-poll loop
timer: every TIMER_INTERVAL_MS (1 s): processDue(20) → claimDue (SKIP LOCKED) → processOne each
SIGTERM → readiness 503 → server.close → workers.stop(): inbox.stop (abort poll) → await startup → await timer run → relay.stop → db.end
```
Why the drain is 65 s: it must exceed the queue's **visibility timeout (60 s)**, so a message received by the instance that was
killed (invisible until the timeout expires) is drained too. Without the drain, a payment made in time could lose to a
timeout just because the saga was restarting. Two tests prove both sides of this (A-2 §3 "Saga process crashes").

## 4. Outbound HTTP: result classification ([order-client.ts:19-52](ecommerce-saga-orchestrator/src/clients/order-client.ts#L19-L52))

| Outcome | Classified as | Saga reaction |
|---|---|---|
| 2xx | `ok` (parsed by a hand-written cast: N-10) | `order-created` / `payment-intent-created` |
| 4xx except 401/408/409/429 | `rejected` with the problem `code` | `order-rejected` → FAILED; `payment-intent-rejected` → CANCELLING |
| 401 | `unavailable` + **drop the cached service token** (key rotation) | retry with backoff |
| 408, 409, 429, 5xx, timeout, network, token failure | `unavailable` | `retrySync`: backoff 1, 2, 4, 8 s … ≤ 30 s, max 5 attempts |

Nuance: **409 is treated as retryable.** That's right for Order's "concurrent modification", but Payment's `ORDER_NOT_PAYABLE` and
`PAYMENT_EXISTS` are also 409 and are permanent, so the saga retries them 5 times before compensating. It's harmless (the same
idempotency key returns the same payment), but it's wasted time. Distinguishing by `code` would be cleaner (P3).

Idempotency keys for these calls are **derived from the saga**: `<sagaId>:create-order` and `<sagaId>:payment-intent`. A retry after a crash or timeout therefore returns the **same** order/payment (test: "instance died after creating the order but
before recording it: a NEW instance resumes with the SAME order").

## 5. Data model recap ([initial-saga-schema.sql](ecommerce-saga-orchestrator/migrations/1791970000000_initial-saga-schema.sql))
`saga_state` enum (13 states, each commented with what it waits for); `saga_instances` (state, ids of order/reservation/
payment, `compensation` JSONB `{awaiting: [...], reasons…}`, `step_attempts`, `deadline_at`, `lease_until`, `version`,
`request` JSONB, `request_hash`); indexes on `deadline_at` (partial), `order_id`, `(state, created_at)`; `saga_steps`
(an append-only audit with `clock_timestamp()`); `outbox` (`seq`, `group_id` for FIFO); `processed_messages`.

## 6. Operating the saga (the admin UI is a thin client over §1)
- **Checkouts needing review** card ([AdminLayout.tsx](ecommerce-frontend/src/pages/admin/AdminLayout.tsx)): MANUAL_REVIEW list (red rows).
- Per saga: the step history (from → to, trigger, detail), **Retry current step now** (non-terminal, not in review),
  **Mark resolved** (review only, with a note).
- SQL for when the UI isn't enough: PHASE-M-3 §1 and §7.
- Resolving is a **human** decision: fix money and goods first (refund in Payments, cancel the order), *then* mark resolved.

## 7. Alternatives considered (and why this design)
| Option | Why not here |
|---|---|
| Temporal / Step Functions for the workflow | They would replace §2–§3 with platform features (durable timers, retries, history), at the cost of a new runtime to operate. Worth it with many workflows |
| Choreography | No single owner for timeouts and "where is checkout X?" |
| Synchronous orchestration (HTTP to every service, no queues) | Availability coupling: one service down stops checkout, and there's no buffering |
| Storing state only in messages | Can't answer "what is stuck?" without a state store |

## Exercises and acceptance criteria (Phase G)
1. For each row of §2, describe the race it prevents with a concrete two-actor timeline.
2. Two saga instances start at once after a deploy, with 50 overdue sagas. Explain exactly how work is divided and why no saga is double-processed.
3. Why must `STARTUP_DRAIN_MS` exceed the visibility timeout? What breaks if it's 10 s?
4. Payment returns 409 `ORDER_NOT_PAYABLE`. Trace what the saga does, attempt by attempt, until it compensates.

**You're done with Phase G when** you can explain the saga's API contract (202 + polling), all seven concurrency
mechanisms, the startup/shutdown order of its loops, and how an operator resolves a manual review safely.
