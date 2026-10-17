# Phase M-2: Observability: Logs, Correlation, Health, Metrics, Alarms, Tracing

## 1. Logs (implemented, good)

| Service | Library | Format | Redaction | Request logging |
|---|---|---|---|---|
| auth, order, payment, saga, notification | `pino` ([saga logger.ts](ecommerce-saga-orchestrator/src/lib/logger.ts)) | JSON, ISO time, `service` field | `authorization`, `cookie`, `set-cookie`, `*.password`, `*.newPassword`, `*.token`, `*.accessToken`, `*.refreshToken`, `*.resetToken`, `*.secret`, `*.cardNumber`, `*.cvv` → `[REDACTED]` | pino-http, health paths skipped |
| inventory | `nestjs-pino` ([logger.options.ts](ecommerce-inventory-service/src/common/logger.options.ts)) | JSON; `req` serialized to id/method/url only | smaller list (`authorization`, `cookie`, `*.password`, `*.token`, `*.secret`) | `/health` skipped |
| product | `structlog` ([logging.py](ecommerce-product-service/app/logging.py)) | JSON, UTC | top-level keys only (`authorization`, `cookie`, `password`, `token`, …). **Nested** keys aren't redacted | "request completed" with `responseTimeMs` |

Why logger-level redaction: call sites forget, the logger doesn't. Tests assert reset and verification tokens never reach
logs (security-review). Logs go to stdout → `awslogs` → CloudWatch `/ecs/<env>-ecommerce-<svc>` (14/30/90-day retention).

**Querying them (CloudWatch Logs Insights, recommended):**
```
fields @timestamp, level, msg, correlationId, sagaId, messageId, err.message
| filter service = "ecommerce-saga-orchestrator" and sagaId = "0192…"
| sort @timestamp asc
```
Locally: `docker compose logs -f saga-orchestrator | npx pino-pretty`.

## 2. Correlation (partially implemented)

| Hop | Propagated? | Evidence |
|---|---|---|
| Browser → any service | accepted if `^[A-Za-z0-9-]{8,128}$`, else a new UUIDv7; echoed as `X-Correlation-Id` + `X-Request-Id` | [request-context.ts](ecommerce-saga-orchestrator/src/middleware/request-context.ts) (same in every service) |
| Service → service **HTTP** (saga→order/payment, payment→order, order→product, auth→notification) | **No.** No client sends `x-correlation-id` (grep: the header appears only in inbound middleware and the frontend) | [order-client.ts](ecommerce-saga-orchestrator/src/clients/order-client.ts) headers: content-type, authorization, idempotency-key |
| Service → message | yes: envelope `correlationId` + `causationId` | outbox writers |
| Saga's own messages | `correlationId = event.correlationId` when reacting to an event; **`saga.id`** for sync steps, timeouts and operator actions | [engine.ts:105-208](ecommerce-saga-orchestrator/src/saga/engine.ts#L105-L208) |

Consequence (M-F3): for one checkout, the browser's correlation id, the Order Service's id for the create call (it
generates its own), and the saga-driven message chain (`saga.id`) are **three different ids**. Today you stitch them with
**business ids** (`sagaId`, `orderId`, `paymentId`), which the logs and saga steps do carry. Fix: forward
`x-correlation-id` in the shared HTTP client helper, and set the saga's message `correlationId` to the checkout request's
correlation id (store it on the saga row).

## 3. Health checks (implemented, good design)

| Endpoint | Meaning | Used by |
|---|---|---|
| `GET /health/live` | process alive; no dependency checks | container `HEALTHCHECK` (Dockerfile + ECS task definition): fails → restart |
| `GET /health/ready` | dependencies OK **and not shutting down**: each check has a 2 s timeout; returns 503 + per-check report | ALB target group: fails → no traffic, no restart |

Why the split matters: if liveness checked the DB, a DB blip would restart **every** task at once (a restart storm) instead
of just pulling them from the load balancer. `/health/*` is blocked at the ALB from the internet.

## 4. Metrics (AWS-native only)

What exists, all from AWS without application code:

| Source | Metrics | Alarms defined |
|---|---|---|
| ALB | 5xx, request count, target response time | ALB 5xx > 10/min ×3; per-service 5xx rate > 5 %; p99 > 2 s |
| ECS / Container Insights (enhanced) | CPU, memory, running task count | running < min; memory > 85 % |
| RDS | CPU, free storage, freeable memory, connections | each (connections > 300: K-F6) |
| DocumentDB | CPU | > 80 % |
| SQS | visible messages, age of oldest | DLQ > 0; main queue age > 300 s |
| WAF | allowed/blocked per rule | none (metrics only) |

**Every alarm targets the alarm topic that CloudWatch can't publish to (P1-1)**, so today none would reach a human.

What's missing (M-F4):
- **Application / business metrics:** checkouts started / completed / failed per minute, sagas per state, sagas in
  `MANUAL_REVIEW`, payment success rate, refunds pending, notification delivery failures, **outbox lag** (age of the
  oldest unpublished row per service), consumer handler latency and error counts.
- **Log-based metric filters** (none in Terraform): e.g. count of `"publish failed; will retry"` or
  `"synchronous step crashed"`.
- **Dashboards** (none).
- **Distributed tracing**: no OpenTelemetry/X-Ray instrumentation (`opentelemetry-api` appears in Product's requirements
  only as a transitive dependency; nothing configures it).

## 5. A minimal observability design that fits this codebase (recommended, not implemented)

Ordered by value per effort:

1. **Fix delivery first:** P1-1 (alarm topic KMS). Without it, nothing below reaches anyone.
2. **Manual-review alert (M-F1):** subscribe an SQS queue or (simplest) an email/Chatbot target to `saga-events` with
   filter `messageType = SagaManualReviewRequired`, **or** a CloudWatch metric (`MANUAL_REVIEW` count from a periodic query,
   or EMF below) with an alarm `> 0`.
3. **Outbox lag (M-F2):** every relay tick logs, or emits as a metric, `oldestUnpublishedAgeSeconds`. Alarm at > 60 s.
   This catches P1-2 and any SNS/SQS outage. The SQL is one line (see M-3).
4. **CloudWatch Embedded Metric Format (EMF):** write metrics as structured JSON log lines (no agent, no new
   infrastructure; CloudWatch extracts them from the existing log stream). Start with the business counters from §4.
5. **Correlation fix** (§2), then **OpenTelemetry** auto-instrumentation (HTTP, pg, AWS SDK, express) exporting to X-Ray
   through an ADOT sidecar. Message hops need manual context propagation (put `traceparent` in the envelope or as an SQS
   attribute). That's an envelope change, which means a contracts release.
6. **Dashboards:** one per environment: golden signals per service (rate, errors, latency, saturation), queue depths and
   ages, outbox lag, the saga state distribution, the payment/refund funnel.

## 6. Alarm → runbook mapping (from runbooks.md, annotated)

| Alarm | Runbook | Note |
|---|---|---|
| running-tasks-low, 5xx, p99, memory, ALB 5xx | Rollback / capacity | fires continuously right after the first apply (image `bootstrap`) |
| dlq-not-empty, oldest-message-age | Dead letters | the admin dead-letters page fails in AWS (K-F2); use the CLI in the runbook |
| postgres-*, docdb-cpu | Database | connection threshold needs a per-class value (K-F6) |
| WAF spikes | console | no alarm defined |
| *(missing)* manual review > 0 | Checkout stuck / MANUAL_REVIEW | M-F1 |
| *(missing)* outbox lag | Outbox stall | M-F2 |
