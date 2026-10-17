# Phase D: Inventory Service and Order Service

Read-only walkthrough on `phase7`. Phase A-2 covered how these services take part in the saga. This phase covers their
**own** APIs, data and code.

---

## Part 1: Inventory Service (NestJS 11 + TypeORM + raw SQL)

### 1.1 Responsibility
Stock per SKU (`on_hand`, `reserved`, `available = on_hand − reserved`), all-or-nothing **reservations** with expiry,
confirm/release/return, stock adjustments, an audit trail of every movement, and low-stock events. It makes **no**
outbound HTTP calls. It's driven by saga commands and admin REST.

### 1.2 Structure
`app.module.ts` → `InventoryModule` (controllers + `StockService`, `ReservationService`, `ExpiryScheduler`),
`AuthModule` (global `AuthGuard`), `HealthModule`, `MessagingModule` (command consumer + outbox relay).
[configure-app.ts](ecommerce-inventory-service/src/configure-app.ts) sets helmet, CORS, body parsing, the global validation pipe,
the problem filter, Swagger, and **`enableShutdownHooks()`** (without it, Nest wouldn't run `beforeApplicationShutdown` on SIGTERM).

### 1.3 Authorization model ([auth.guard.ts](ecommerce-inventory-service/src/auth/auth.guard.ts))
A **global guard**: routes without `@Roles` are public, but a **present** token is always verified ("a broken client fails
loudly instead of silently acting anonymously"). `@Roles("admin")`, `@Roles("service", "admin")`, `@Roles("service")`.
`GET /api/v1/inventory/:sku` is public and returns **availability only** (`{available, inStock}`). Admins get the full record.
Unknown SKUs are "not in stock", not 404, so the endpoint doesn't confirm which SKUs exist.

### 1.4 Validation ([validation.pipe.ts](ecommerce-inventory-service/src/common/validation.pipe.ts), [dto.ts](ecommerce-inventory-service/src/inventory/dto.ts))
class-validator with `whitelist + forbidNonWhitelisted + transform`: **unknown fields are rejected** (400 with per-field
errors), not silently dropped. Bounds: quantity 1–1000, ≤ 100 lines, TTL 60–86400 s, delta ±100 000, threshold ≤ 1 000 000.

### 1.5 Endpoints → code

| Endpoint | Roles | Code | Notes |
|---|---|---|---|
| `GET /api/v1/inventory` | admin | `StockService.list` | **keyset pagination by SKU** (`sku > cursor`), optional prefix filter with `LIKE` escaping of `% _ \` |
| `GET /inventory/low-stock` | admin | `lowStock` | `available <= low_stock_threshold`; declared before `:sku` so it isn't captured as a SKU |
| `GET /inventory/:sku` | public / admin | `availability` / `get` | see §1.3 |
| `GET /inventory/:sku/movements` | admin | `movements` | the newest 200 audit rows |
| `PATCH /inventory/:sku` | admin + `Idempotency-Key` | [stock.service.ts `adjust`](ecommerce-inventory-service/src/inventory/stock.service.ts) | restock / write-off / correction / threshold |
| `POST /inventory/reservations` | service, admin | `ReservationService.reserve` | 201 / 200 replay / 409 `INSUFFICIENT_STOCK` / 422 key reuse |
| `GET /reservations/:id`, `POST …/confirm`, `POST …/release` | service (admin for get) | confirm/release | the saga uses the **command** path instead (same service methods) |

### 1.6 Stock adjustment, line by line (`adjust` → `applyAdjustment`)
1. Input rules: delta and/or threshold required; a delta needs a reason and must be non-zero.
2. Idempotency: `INSERT INTO idempotency_records (key = 'adjust:<sku>:<Idempotency-Key>', request_hash) ON CONFLICT DO NOTHING`.
   Already present + same hash → return the **stored response** (`Idempotency-Replayed: true`). Different hash → 422.
3. `SELECT … FOR UPDATE` on the stock row. A missing row with a positive delta **creates** the SKU (first receipt).
4. Guard: `on_hand + delta < reserved` → 409 `WOULD_UNDERCUT_RESERVATIONS` (you can't write off stock someone has reserved).
5. Update, insert a `stock_movements` row (actor, correlation id, note), and emit `InventoryLowStock` **only on the transition** into low stock (not on every write).
6. Store the response body in the idempotency record. All of this is **one transaction**, so a failure rolls back the claim too.

This is the generic **"idempotency record" pattern** (key + request hash + stored response) used by Stripe-style APIs.
Reservations use a **different** pattern: the key is a unique column on the business row itself (Phase A-2), which is
simpler because the row *is* the response.

### 1.7 Reservations recap and the lifecycle
`ACTIVE → CONFIRMED → RETURNED` and `ACTIVE → RELEASED | EXPIRED`, or `REJECTED` (nothing held). The DB enforces
`reserved <= on_hand`, non-negative columns, the SKU format, one **live** reservation per order (partial unique index), and
expiry after creation. Expiry: [expiry.scheduler.ts](ecommerce-inventory-service/src/inventory/expiry.scheduler.ts) every 30 s
on every instance, with `FOR UPDATE SKIP LOCKED` so instances split the work, and a `running` flag so sweeps never overlap.

### 1.8 Migrations ([data-source.ts](ecommerce-inventory-service/src/database/data-source.ts))
`synchronize: false` **always**; `migrationsTransactionMode: "each"`; the same options for the app and the CLI.
[AddReservationReturned](ecommerce-inventory-service/src/database/migrations/1792051200000-AddReservationReturned.ts) is a
good lesson in Postgres enums. `ALTER TYPE … ADD VALUE` is fine inside a transaction (PG ≥ 12, if the value isn't used in the same
transaction). The `down` has to **recreate** the type, because Postgres can't drop an enum value, and it deliberately fails while
`RETURNED` rows exist. Expand → contract with enums means: add the value first; code uses it next release; removing a value is a
separate, data-checked migration. Readiness also reports "not ready" while a migration shipped in the image is unapplied
(commit "Readiness: not ready while a migration shipped in the image is unapplied").

### 1.9 Alternatives
- Row-level `UPDATE … WHERE available >= qty` (used) vs `SELECT … FOR UPDATE` then check vs Redis counters: the
  single-statement version is the simplest correct choice in Postgres. Redis is faster but needs its own durability and reconciliation.
- Event-sourced stock ledger: `stock_movements` already gives you an audit trail without making it the source of truth.

### 1.10 Observations (new, small)
- `CreateReservationDto.lines` has no `@ArrayUnique` on SKU, and the command schema has no `uniqueItems`. A duplicate SKU
  would hit the `reservation_lines` primary key and fail as a 500 (REST) or retry → DLQ (command). It's unreachable from the
  saga today, because Order rejects duplicate SKUs first ([order.schemas.ts:32](ecommerce-order-service/src/orders/order.schemas.ts#L32)),
  but the service shouldn't depend on that (P3: add the validation).
- Inventory uses `jose` 5 and is CommonJS, unlike the other Node services (N-31).

### 1.11 Tests ([test/](ecommerce-inventory-service/test))
`reservations.spec.ts` (all-or-nothing, concurrent no-oversell, expiry, idempotency), `stock.spec.ts` (adjustments,
undercut guard, low-stock transition, "every event … is schema-valid"), `messaging.spec.ts` (commands over Floci,
duplicates re-answer, DLQ for invalid), `openapi.spec.ts` (drift **and real responses validated against the documented schemas**).

---

## Part 2: Order Service (Express 5 + Mongoose 9, MongoDB 8 / DocumentDB 5)

### 2.1 Responsibility
Orders with **immutable line snapshots** (name, unit price at purchase time), totals (subtotal, coupon discount, tax,
shipping), the status state machine and its history, cancellation, and admin fulfillment.

### 2.2 Endpoints → code ([order.routes.ts](ecommerce-order-service/src/orders/order.routes.ts))

| Endpoint | Role | Behavior |
|---|---|---|
| `POST /api/v1/orders` | **service** (the saga) | create PENDING; Idempotency-Key required; 201 new / 200 replay. "Never by the browser directly" (line 43) |
| `GET /orders`, `/orders/my-orders` | customer, admin | customers always see only their own (`customerId` forced); admins all; keyset pagination on UUIDv7 `_id` |
| `GET /orders/:id` | customer, admin | **404 for someone else's order** (not 403, so existence isn't revealed) |
| `POST /orders/:id/cancel` | customer, admin | before payment → CANCELLED; after (CONFIRMED/PROCESSING) → CANCELLATION_PENDING (the saga refunds). Reason `ADMIN` when an admin cancels someone else's order |
| `GET /admin/orders`, `PATCH /admin/orders/:id/status` | admin | fulfillment only: `PROCESSING | SHIPPED | DELIVERED` (FulfillmentRequest enum), still through `canTransition` |
| `GET /internal/v1/orders/:id` | service | the **authoritative amount**, owner, status, version (for Payment) |
| `POST /internal/v1/orders/:id/transitions` | service | REST twin of the `OrderStatusTransitionRequested` command; `cancellationReason` required for CANCELLED |

### 2.3 Pricing ([pricing.ts](ecommerce-order-service/src/orders/pricing.ts)): money done right
- All arithmetic is **BigInt** in minor units, so no float, and no overflow in `amount × basis points`.
- The coupon is a percentage of the subtotal, **floored** (never over-discount), optionally capped and with a minimum.
- The discount is **allocated across lines by the largest-remainder method** ([allocate](ecommerce-order-service/src/orders/pricing.ts#L72-L85)),
  so per-line discounts are integers, proportional, and **sum exactly** to the order discount (a refund of one line later is exact).
- Tax is **per line** on (subtotal − line discount), **half-up** (`(n·2 + d) / (2d)`).
- Free shipping when (subtotal − discount) ≥ threshold. Grand total = subtotal − discount + tax + shipping.
- `toSafeNumber` refuses to put a value above 2^53 into JSON, failing instead of silently rounding.

Prices come only from Product's internal lookup ([catalog-client.ts](ecommerce-order-service/src/orders/catalog-client.ts):
service token for the Product audience, timeout, a 401 drops the cached token and retries once, outage → 503
`DEPENDENCY_UNAVAILABLE`). The request carries **no prices**. Tax rate, shipping and coupons are env config (`TAX_RATE_BPS`,
`SHIPPING_FEE_MINOR`, `FREE_SHIPPING_THRESHOLD_MINOR`, `COUPONS` JSON). There's no per-customer coupon usage limit
(fine for a demo; real coupons need a redemption ledger).

### 2.4 Persistence ([order.model.ts](ecommerce-order-service/src/orders/order.model.ts), [mongo.ts](ecommerce-order-service/src/db/mongo.ts))
- One document per order: items, totals (Int64), address, `statusHistory[]`, **`outbox[]`**, `version`, `relayLeaseUntil`.
  `strict: "throw"`: unknown fields are an error, not silently dropped.
- Indexes (created by the migrate job `sync-indexes`, `autoIndex: false` in the app): unique `idempotencyKey`;
  `(customerId, _id desc)`; `(status, _id desc)`; sparse `outbox.createdAt` for the relay.
- `useBigInt64: true` reads money as native bigint. A dedicated connection (not the mongoose global), `maxPoolSize 20`.
- **Why embed the outbox?** MongoDB is atomic per document: status + history + events in one conditional
  `findOneAndUpdate({_id, status, version})` (Phase A-2). There are no multi-document transactions, so no replica set is needed locally.

### 2.5 DocumentDB readiness
DocumentDB is "MongoDB-compatible" with gaps. The code guards against them:
- the config refuses a DocumentDB URI without `tls=true` and `retryWrites=false` (DocumentDB has no retryable writes);
- the RDS CA bundle is downloaded, checksum-pinned, into the image (Dockerfile `certs` stage) and used automatically;
- [documentdb-compat.test.ts](ecommerce-order-service/tests/documentdb-compat.test.ts) **scans the source** for every `$operator`
  and fails if one isn't on a DocumentDB 5.0 allowlist (`$set $inc $push $pull $each $lt $gte $or $exists …`), and rejects
  `$where`/`$function` (server-side JS). It includes a self-test that the guard catches `$where`.

What's still unverified: the real suite has never run against DocumentDB (N-24).

### 2.6 State machine and cancellation
See [state-machine.ts](ecommerce-order-service/src/orders/state-machine.ts) (Phase A-2 has the diagram). Important properties:
explicit allowed transitions; the same transition requested twice = `changed: false` (idempotent) + a re-emitted outcome
event for the saga; an invalid transition from a command is **acknowledged** (FIFO group would block otherwise) and logged.

### 2.7 Alternatives
- MongoDB document-per-order vs relational `orders` + `order_lines`: documents fit an immutable, read-mostly order snapshot
  well, and embedded events give atomicity cheaply. Relational wins for cross-order reporting (use a read model or export).
- Synchronous pricing at create time (used) vs prices in the checkout request (insecure: the client sets prices) vs a price
  cache from Product events (eventual: could charge an outdated price).

### 2.8 Tests ([tests/](ecommerce-order-service/tests))
`orders.test.ts` (create/replay/key reuse, ownership 404s, cancellation before/after payment, "each change queues
schema-valid events in the SAME document write"), `pricing.test.ts` (allocation sums, half-up, caps, free shipping),
`messaging.test.ts` (FIFO commands, DLQ), `outbound-clients.test.ts` (token caching, 401 retry, 503 mapping),
`documentdb-compat.test.ts`, `request-hash.test.ts` (item order doesn't change the hash), `openapi`, `event-schemas`.

## Exercises and acceptance criteria (Phase D)
1. With a 10 % coupon on lines of ₹333.33 and ₹666.67, compute the discount allocation by hand using the
   largest-remainder method, then check it against [pricing.ts:72-85](ecommerce-order-service/src/orders/pricing.ts#L72-L85).
2. Explain why `PATCH /inventory/:sku` uses an idempotency-record table while reservations use a unique column.
3. Explain why an invalid order transition from the FIFO queue is acknowledged instead of retried.
4. Name three DocumentDB differences this code guards against, and how.

**You're done with Phase D when** you can trace an admin restock and a customer cancellation end to end, explain each DB
constraint/index and why it exists, and compute an order total with discount and tax by the code's rules.
