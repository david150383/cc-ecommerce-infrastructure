# Phase M-3: Troubleshooting Playbook (Symptom → Diagnosis → Fix)

All commands are **recommendations** to run yourself; none were executed for this analysis. The local commands assume
`ecommerce-infrastructure/` and the compose stack. AWS equivalents are given where they differ. Read-only queries
first; anything that changes state is marked **⚠ changes state**.

Local helpers:
```bash
psql_saga() { docker compose exec -T postgres psql -U saga_svc -d saga_db -c "$1"; }
aws_local() { AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url http://localhost:4566 "$@"; }
```

---

## 1. "My checkout is stuck on PROCESSING"

1. Find the saga: the browser polls `GET /api/v1/checkout/{sagaId}`, and the admin page shows the step history.
2. Look at its state and deadline:
   ```sql
   SELECT state, step_attempts, deadline_at, lease_until, failure_reason, compensation
   FROM saga_instances WHERE id = '<sagaId>';
   SELECT from_state, to_state, trigger, detail, at FROM saga_steps WHERE saga_id = '<sagaId>' ORDER BY id;
   ```
3. Decide by state:

| State | Waiting for | Check |
|---|---|---|
| `STARTED` | the Order Service HTTP call | saga logs `synchronous step crashed`, Order health, service-token errors (401 → Auth `SERVICE_CLIENTS`) |
| `RESERVING_INVENTORY` | `InventoryReserved` / `…Failed` | outbox published? (§5); inventory-commands depth; inventory logs |
| `INVENTORY_RESERVED` | the Payment intent HTTP call | Payment health; Payment → Order internal call |
| `CONFIRMING_*` / `CANCELLING` / `REFUNDING` | result events | the receiving service's queue + logs; the saga re-sends on each timeout (step_attempts rising) |

4. If the dependency is back: Admin → **Retry current step now** (sets `deadline_at = now()`). ⚠ changes state.

## 2. "Customer paid but the order isn't confirmed"

1. Payment side: `SELECT status, provider_session_id, updated_at FROM payments WHERE order_id = '<orderId>';` (payment_db)
   - Still `PENDING` → the webhook didn't arrive or was rejected. Check payment logs for `webhook signature rejected` (wrong
     `STRIPE_WEBHOOK_SECRET`, or the WAF blocking webhooks) and `session … not known (yet)`. Reconciliation polls
     the provider after `RECONCILE_AFTER_SECONDS` (300 s).
   - `SUCCEEDED` → `PaymentSucceeded` is in Payment's outbox: is it published? (§5)
2. Saga side: if the saga is `CONFIRMING_INVENTORY`, look at Inventory (reservation expired → refund path). If
   `MANUAL_REVIEW`, read `failure_reason` and follow the runbook. **Never** refund by hand while the saga is still
   compensating; it will refund itself.

## 3. Messages missing, delayed, duplicated, or failing repeatedly

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| **Missing**: event never reached a consumer | not published (outbox stall); filter policy doesn't include the type; wrong topic/queue name | outbox lag query (§5); `aws_local sns list-subscriptions` and the subscription's `FilterPolicy`; `verify-local-messaging.sh` | fix the relay error; add the type to the filter policy (Terraform) |
| **Delayed** | relay interval / backlog; consumer down; visibility timeout after a crash (60 s) | queue `ApproximateNumberOfMessages` and `ApproximateAgeOfOldestMessage` | scale consumers; check crash loops |
| **Duplicated** | at-least-once (expected): relay crash after send, visibility expiry during a slow batch | the same `messageId` twice in consumer logs ("duplicate event ignored") | nothing, if consumers are idempotent (they are); investigate only if side effects doubled |
| **Repeatedly failing** | poison message (schema-invalid → `InvalidCommand`) or a persistent dependency error | consumer logs at error level with `messageId`, `receiveCount`; after 5 receives → DLQ | fix the producer or the dependency; redrive (runbook) |

Queue inspection:
```bash
aws_local sqs get-queue-attributes --queue-url http://localhost:4566/000000000000/local-ecommerce-saga-inbox \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage
# peek at a DLQ without consuming (visibility 0):
aws_local sqs receive-message --queue-url http://localhost:4566/000000000000/local-ecommerce-notification-commands-dlq \
  --visibility-timeout 0 --attribute-names All --max-number-of-messages 10
```
⚠ Redrive changes state: `aws sqs start-message-move-task --source-arn <dlq> --destination-arn <queue>` (safe to repeat because
consumers are idempotent, as the drill showed).

## 4. Dead letters

Follow [runbooks.md §Dead letters](ecommerce-infrastructure/docs/architecture/runbooks.md). In AWS, the admin
"Dead letters" page will fail until K-F2 is fixed, so use the CLI. Decide **poison vs valid-but-failed** before redriving:
redriving poison just sends it back to the DLQ after 5 more receives.

## 5. Outbox stall (nothing is being published)

```sql
-- saga_db: unpublished rows, oldest first, with attempts
SELECT seq, message_type, destination, attempts, now() - created_at AS age
FROM outbox WHERE published_at IS NULL ORDER BY seq LIMIT 10;

-- the same idea in payment_db / inventory_db / auth_db (table "outbox", columns published_at / created_at)
SELECT count(*), max(now() - created_at) AS oldest FROM outbox WHERE published_at IS NULL;
```
```javascript
// order_db (Mongo): documents with pending events
db.orders.find({ "outbox.0": { $exists: true } }, { _id: 1, relayLeaseUntil: 1, "outbox.messageType": 1 }).limit(10)
```
- One row with high `attempts` at the head and everything else waiting behind it → **P1-2**: a poison row (wrong destination,
  missing queue, oversized body). Logs: `publish failed; will retry` with `destination`. Fix the configuration. As a last
  resort, ⚠ mark that row published after copying its envelope somewhere safe, so the others flow again. Then fix the code.
- All rows aging and the logs show credential or endpoint errors → IAM/endpoint problem (in AWS: the task role or VPC endpoint).

## 6. HTTP-level symptoms

| Symptom | Where | Likely cause |
|---|---|---|
| 401 everywhere after an Auth deploy | all services | signing key rotated without overlap; JWKS cached (product caches 600 s). Follow the rotation runbook (add the new kid first) |
| 401 on service-to-service calls only | saga/order/payment logs | wrong `SERVICE_CLIENT_SECRET` or a hash mismatch in Auth `SERVICE_CLIENTS`; audience not allowed (403 `AUDIENCE_NOT_ALLOWED`) |
| 429 `RATE_LIMITED` / WAF 403 | auth endpoints | in-memory limiter (30/min/IP) or WAF `rate-auth`; CGNAT users share IPs; check `TRUST_PROXY_HOPS` (all users looking like one IP = wrong hops) |
| 429 `TOO_MANY_ACTIVE_CHECKOUTS` | saga | a customer with 3 open checkouts (by design: S-1) |
| 502/503 bursts during deploys | ALB | the shutdown sequence (M-F5); readiness failing (DB connections: K-F6) |
| 504 after ~30 s | CloudFront | origin read timeout 30 s; slow DB query (check `log_min_duration_statement` logs) |
| `remaining connection slots are reserved` | any Postgres service | K-F6 connection budget |

## 7. Saga-specific commands

```sql
-- distribution of states (spot pile-ups)
SELECT state, count(*) FROM saga_instances GROUP BY 1 ORDER BY 2 DESC;
-- overdue but not processed (timer loop stuck? lease stuck?)
SELECT id, state, deadline_at, lease_until FROM saga_instances
WHERE deadline_at < now() - interval '2 minutes' AND state NOT IN ('COMPLETED','CANCELLED','FAILED','RESOLVED') LIMIT 20;
-- money in limbo
SELECT id, order_id, payment_id, failure_reason, updated_at FROM saga_instances WHERE state = 'MANUAL_REVIEW';
```
Resolve: Admin → Mark resolved with a note (⚠ changes state; only after money and goods agree).

## 8. Local environment problems

See [local-development.md §Troubleshooting](ecommerce-infrastructure/docs/architecture/local-development.md) (BuildKit
stalls, lockfile platform deps, Mongo slow health, `docker builder prune`). On your 8 GB machine, run infrastructure plus only
the services involved, with `--no-deps`. Remember that this skips the `*-migrate` jobs.
