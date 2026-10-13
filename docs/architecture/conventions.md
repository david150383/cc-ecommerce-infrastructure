# Platform Conventions

Every repository follows these conventions. Until `ecommerce-contracts` exists
(Phase 6), each repository restates the parts it implements in its own
`docs/`. When a repo's docs disagree with this file, this file wins. Fix the
repo.

## API versioning

- Public routes live under `/api/v1/...`. A breaking change gets a new major path
  (`/api/v2`), and both versions run side by side during the deprecation window.
- Internal service-to-service routes live under `/internal/v1/...`. They require
  a **service token** and are never routed through the public load balancer.
- Health routes are not versioned: `GET /health/live` and `GET /health/ready`.
- Additive changes (new optional fields, new endpoints) are not breaking.
  Removing or renaming fields, tightening validation, or changing meaning are breaking.

## Identifiers

| ID | Format | Who generates it |
|---|---|---|
| Entity IDs (`userId`, `orderId`, `paymentId`, ...) | UUID v7 (time-ordered) as a string | The owning service |
| `sagaId` | UUID v7 | Saga Orchestrator |
| `eventId` / `commandId` | UUID v7 | Producer, once per message (reused on retry) |
| `correlationId` | UUID v7 | The first service to receive a request without one |
| `causationId` | The `eventId`/`commandId` of the message that caused this one, or the inbound request's `X-Request-Id` | Producer |
| `idempotencyKey` | Opaque string ≤ 255 chars | The caller that wants exactly-once *effect* |
| SKU | `^[A-Z0-9][A-Z0-9-]{2,63}$` | Product Service |

## HTTP headers

| Header | Direction | Meaning |
|---|---|---|
| `Authorization: Bearer <jwt>` | request | User access token or service token |
| `X-Correlation-Id` | request + response | Propagated end-to-end. Generated if missing, echoed in the response, included in every log line and message |
| `X-Request-Id` | response | Unique per HTTP request handled by this service |
| `Idempotency-Key` | request | Required on every non-idempotent `POST` that creates or changes money, stock or orders |
| `Idempotency-Replayed: true` | response | Set when the response came from the idempotency store |

### Idempotency-Key semantics (HTTP)

1. The server stores `(key, caller, request-hash) → (status, response body)` for at least 24h.
2. Same key and same request hash means **replay the stored response**. The
   operation is not repeated.
3. Same key and a *different* request hash returns `422` with error code `IDEMPOTENCY_KEY_REUSED`.
4. Same key while the first request is still running returns `409` with error
   code `IDEMPOTENCY_IN_PROGRESS`. The client retries later.

## Money

```json
{ "amountMinor": 49900, "currency": "INR" }
```

- `amountMinor` is an integer in the currency's minor unit (paise, cents).
  JavaScript code must keep it under `Number.MAX_SAFE_INTEGER`. Values are
  validated as integers ≥ 0 unless a field is documented as signed.
- `currency` is an ISO 4217 alphabetic code. One order has exactly one currency.
- Never use floating point. Percentages (tax, discount rates) are expressed in
  **basis points** (`taxRateBps: 1800` = 18%). Rounding rule: half-up, applied
  once per line item.

## Time

- Always UTC, serialized as RFC 3339 with a `Z` suffix: `2026-10-13T09:30:00.000Z`.
- Field names end in `At` (`createdAt`, `occurredAt`, `expiresAt`).

## Error responses: RFC 9457 Problem Details

Every 4xx or 5xx response has `Content-Type: application/problem+json`:

```json
{
  "type": "https://errors.ecommerce.local/validation-failed",
  "title": "Request validation failed",
  "status": 400,
  "code": "VALIDATION_FAILED",
  "detail": "One or more fields are invalid.",
  "instance": "/api/v1/auth/register",
  "correlationId": "01929a3e-7c1b-7f00-9b1e-1f2a3b4c5d6e",
  "errors": [{ "path": "email", "message": "Invalid email address" }]
}
```

- `code` is a stable, SCREAMING_SNAKE_CASE identifier that clients can branch on.
- `errors` appears only for validation failures.
- 5xx responses never include stack traces, SQL, or internal hostnames.
  `detail` is generic, and the real cause is logged with the `correlationId`.

Common codes: `VALIDATION_FAILED` (400), `UNAUTHENTICATED` (401), `FORBIDDEN` (403),
`NOT_FOUND` (404), `CONFLICT` (409), `IDEMPOTENCY_IN_PROGRESS` (409),
`IDEMPOTENCY_KEY_REUSED` (422), `RATE_LIMITED` (429), `INTERNAL_ERROR` (500),
`DEPENDENCY_UNAVAILABLE` (503).

## Pagination

Lists use cursor pagination by default (`?limit=20&cursor=...`). The Product
catalog also supports `?page=` for SEO-friendly listing pages.

```json
{ "data": [], "page": { "limit": 20, "nextCursor": "opaque-or-null" } }
```

## Authentication

| Property | Value |
|---|---|
| Algorithm | `RS256` (asymmetric, so verifiers never hold the signing key) |
| Issuer (`iss`) | `ecommerce-auth-service` (configurable as `JWT_ISSUER`) |
| User token audience (`aud`) | `ecommerce-api` |
| Service token audience | The target service name, e.g. `ecommerce-order-service` |
| Access token lifetime | 15 minutes |
| Refresh token lifetime | 30 days absolute, 7 days idle. Rotated on every use; reuse of an old token revokes the whole session family |
| Claims | `sub` (userId or service name), `roles` (`["customer"]`, `["admin"]`, `["service"]`), `sid` (session id), `jti`, `iat`, `exp`, `iss`, `aud` |
| Key distribution | `GET /.well-known/jwks.json` on the Auth Service; tokens carry `kid` |
| Key rotation | A new key is published in JWKS ≥ 24h before it starts signing. The old key stays in JWKS until every token it signed has expired (≥ 15 min after retirement). Verifiers cache JWKS for 10 minutes and refetch on an unknown `kid` (rate-limited) |
| Clock skew tolerance | 30 seconds |

Browser refresh tokens live in an `HttpOnly; Secure; SameSite=Strict` cookie
scoped to `Path=/api/v1/auth`. The access token is kept **in memory only**
(not localStorage). Cookie-authenticated endpoints (`/refresh`, `/logout`)
require a CSRF double-submit token (`X-CSRF-Token` header must match the
`csrf_token` cookie).

Service-to-service calls use short-lived service tokens obtained through a
client-credentials grant at Auth's `POST /internal/v1/auth/service-token`.

## Message envelope (events and commands)

Every message on SNS/SQS uses this envelope. The schema file
`events/schemas/envelope.v1.schema.json` is copied into each producing
repository until Phase 6.

```json
{
  "messageId": "0192a1b2-0000-7000-8000-000000000001",
  "messageKind": "event",
  "messageType": "OrderConfirmed",
  "messageVersion": 1,
  "producer": "ecommerce-order-service",
  "occurredAt": "2026-10-13T09:30:00.000Z",
  "correlationId": "0192a1b2-0000-7000-8000-0000000000aa",
  "causationId": "0192a1b2-0000-7000-8000-0000000000bb",
  "sagaId": "0192a1b2-0000-7000-8000-0000000000cc",
  "idempotencyKey": null,
  "payload": { }
}
```

| Field | Rule |
|---|---|
| `messageKind` | `event` = a fact that already happened, named in the past tense. `command` = a request to do something, which may be rejected |
| `messageType` | PascalCase name, also sent as SNS/SQS message attribute `messageType` for filter policies |
| `messageVersion` | Integer major version of the payload schema. Additive changes keep the version |
| `idempotencyKey` | **Required for commands.** The consumer must make the *effect* happen at most once per key |
| `sagaId` | Present on everything that belongs to a checkout saga, otherwise `null` |
| `payload` | Never contains passwords, tokens, reset links, card data, or secrets |

### Consumer rules (at-least-once delivery)

SNS and SQS standard queues deliver **at least once** and **without ordering
guarantees**. So every consumer must follow these rules:

1. **Dedupe by `messageId`** in a `processed_messages` table, inside the *same*
   database transaction as the business change.
2. **Delete the SQS message only after commit.** If the process crashes before
   deletion, the message reappears after the visibility timeout. Step 1 makes
   the redelivery harmless.
3. **Tolerate out-of-order arrival.** Check the current state before applying
   (e.g. ignore `InventoryReserved` for a saga that has already been cancelled).
4. **Fail loudly into the DLQ.** Poison messages stop retrying after
   `maxReceiveCount` and alarm on the DLQ depth.

### Producer rules: transactional outbox

A service never publishes directly inside a request handler. It writes the
message into an `outbox` table **in the same transaction** as the state change.
A relay then publishes outbox rows to SNS/SQS and marks them sent. If the relay
crashes after publishing but before marking a row, the message is sent twice,
which the consumer rules above handle. The result is *at-least-once publication
with no lost messages*. It is **not** exactly-once execution, and nothing in
this platform claims to be.

## Logging

- JSON logs to stdout (pino / structlog), one object per line.
- Required fields: `level`, `time`, `service`, `correlationId`, `msg`. Add
  `sagaId`, `orderId` and `messageId` when known.
- Redact at the logger level: `authorization`, `cookie`, `set-cookie`,
  `password`, `token`, `refreshToken`, `resetToken`, `secret`, `card*`, `cvv`.

## Ports (local)

| Service | Port |
|---|---|
| auth | 4001 |
| product | 4002 |
| inventory | 4003 |
| order | 4004 |
| payment | 4005 |
| notification | 4006 |
| saga | 4007 |
| frontend | 5173 |
