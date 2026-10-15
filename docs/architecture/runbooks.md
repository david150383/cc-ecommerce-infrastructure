# Runbooks

What to do when something breaks. Each entry: the signal (usually an alarm from `terraform/modules/*`),
the steps, and how it was **drilled**. The drills run locally (`scripts/drills/`, compose stack); their real
output is at the end. AWS commands are the production equivalents. They have not been run, because
nothing is deployed yet.

## Rollback (a bad release)

Signals: `*-running-tasks-low`, `*-5xx`, `*-p99-latency`, or the deploy job failed.

1. **Automatic (ECS):** a release whose new tasks never become healthy is rolled back by the deployment
   circuit breaker; the deploy job then fails with `rollout failed; ECS rolled back`. Nothing to do but read
   the logs (`/ecs/<env>-ecommerce-<service>`).
2. **Healthy but wrong** (passes health checks, misbehaves): roll back to the previous revision. Images are
   immutable and tagged with the commit SHA, so a revision is exact:
   ```bash
   aws ecs describe-services --cluster prod-ecommerce --services order-service \
     --query 'services[0].deployments[*].[taskDefinition,status]'          # current
   aws ecs list-task-definitions --family-prefix prod-ecommerce-order-service --sort DESC --max-items 3
   aws ecs update-service --cluster prod-ecommerce --service order-service \
     --task-definition prod-ecommerce-order-service:<previous revision>
   aws ecs wait services-stable --cluster prod-ecommerce --services order-service
   ```
   Or re-run the deploy workflow for the previous commit.
3. **Migrations are never rolled back by hand.** They are expand-only (the previous release must work with
   the new schema; see deployment.md), so rolling the code back is enough. A wrong migration is fixed by a new
   forward migration.
4. **Frontend:** re-run its deploy workflow for the previous commit (the bucket is versioned too).
5. Messages that arrived while the bad release ran wait in SQS (or the DLQ after 5 failed receives: see
   *Dead letters*). Nothing to replay by hand.

*Drilled* (`scripts/drills/rollback.sh`): a release that crashes at startup was deployed, detected (readiness
down, restart loop), and rolled back. A command sent while it was broken was processed after the rollback.
Healthy again after 6 s and 262 s in two runs (the second on a loaded, swapping laptop): measure the real
figure in staging.

## Database restore (data loss or corruption)

Signals: a bad migration or operator error; data reported missing. **Stop the writers first**
(`aws ecs update-service --desired-count 0` for the affected service) so nothing writes to the damaged copy.

- **PostgreSQL (RDS):** point-in-time restore to a NEW instance just before the incident (backups: 14 days in
  prod), verify, then move the service over (swap its `DATABASE_URL` in the secret, redeploy):
  ```bash
  aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier prod-ecommerce-postgres \
    --target-db-instance-identifier prod-ecommerce-postgres-restore --restore-time 2026-10-15T07:40:00Z \
    --db-subnet-group-name prod-ecommerce-postgres --vpc-security-group-ids <db sg> --no-publicly-accessible
  ```
  One instance holds six service databases: to repair ONE of them, `pg_dump` that database from the restored
  instance and `pg_restore` it into a new database on the live instance, then swap.
- **DocumentDB:** `aws docdb restore-db-cluster-to-point-in-time` to a new cluster, then the same with
  `mongodump`/`mongorestore` for `order_db`.
- **After a restore:** events published after the restore point exist in other services but not in the
  restored database. Reconcile with the outbox/saga state: the saga's step history and the Payment Service's
  reconciliation job show what happened; open MANUAL_REVIEW sagas for anything inconsistent.

*Drilled* (`scripts/drills/postgres-restore.sh`, `scripts/drills/mongo-restore.sh`): rows/orders deleted from
a copy, restored from the backup into a new database, and verified identical: per-table row counts plus a
content hash, and all MongoDB indexes, including the unique idempotency index.

## Dead letters

Signals: `*-dlq-not-empty` (messaging module), or the admin page *Notifications → Dead letters*.

1. Look at the messages without consuming them: admin page, or
   `aws sqs receive-message --visibility-timeout 0 --queue-url <dlq> --attribute-names All`.
2. Find the cause in the consumer's logs (it logs `messageId`, type and the reason at error level).
3. **Poison message** (it can never succeed: invalid, unknown type): fix the producer; keep the message for
   the record, then delete it. **Valid message that failed** (a dependency was down): fix the cause, then
   redrive:
   ```bash
   aws sqs start-message-move-task --source-arn <dlq arn> --destination-arn <queue arn>
   aws sqs list-message-move-tasks --source-arn <dlq arn>
   ```
   Every consumer is idempotent (deduplication by `messageId` and by business key): a redrive, even twice,
   never applies a message twice.

*Drilled* (`scripts/drills/dlq-redrive.sh`): a valid command in the notification DLQ was redriven with
`start-message-move-task` and processed once. Redriving the same message again created no duplicate.

## Checkout stuck / saga in MANUAL_REVIEW

Signals: the admin overview "Checkouts needing review", saga logs.

1. Admin → Checkouts → the saga: the step history shows what happened and what the saga was waiting for.
2. If a step is waiting on a dependency that is back: **Retry current step now**.
3. If money and goods disagree (e.g. paid, but the reservation was lost and the refund failed): fix it by hand
   (refund from Payments, cancel the order), then **Mark resolved** with what you did; the note is kept.

*Drilled* in Phases 3–4 (`verify-checkout-saga.py`): a saga SIGKILLed while the payment event arrived resumed
from its inbox after restart and completed.

## Secret rotation

| Secret | How | Downtime |
|---|---|---|
| JWT signing key | add a new `{kid, pem}` to `JWT_SIGNING_KEYS` (kids sort by date: the newest signs), redeploy Auth; remove the old key only after `JWT_ACCESS_TTL_SECONDS` | none: old tokens still verify against the JWKS |
| Service client secret | add the new secret's hash to Auth's `SERVICE_CLIENTS` next to the old one, deploy Auth; put the new secret into the client's secret, deploy it; remove the old hash | none |
| Stripe keys / webhook secret | roll in the Stripe dashboard (it keeps the old webhook secret valid for a grace period), update the payment secret, redeploy | none |
| Database passwords | RDS/DocumentDB master: managed and rotated by AWS. Service roles: `ALTER ROLE … PASSWORD`, update the secret, redeploy | brief reconnects |
| Suspected leak of anything | rotate first, investigate second; check CloudTrail for use of the old value | |

## Alarm → runbook

| Alarm | Runbook |
|---|---|
| `*-running-tasks-low`, `*-5xx`, `*-p99-latency`, `*-memory-high`, `*-alb-5xx` | Rollback (if after a deploy), else logs and capacity |
| `*-dlq-not-empty`, `*-oldest-message-age` | Dead letters |
| `*-postgres-*`, `*-docdb-cpu` | Database: connections/CPU (scale up, look for slow-query logs: `log_min_duration_statement` = 1 s) |
| WAF `rate-auth` / `rate-api` spikes | Expected under attack; check sampled requests in the WAF console |

## Drill log (2026-10-15, local stack)

### PostgreSQL restore (`payment_drill`, a copy of `payment_db`)
```text
1. backup payment_drill (pg_dump, custom format)
      26086 bytes; tables: 5
2. disaster: an operator deletes rows by mistake
   damaged: outbox lost rows (fingerprint changed)
3. restore into a NEW database payment_drill_restored
4. verify: every table identical to the backup? YES
   restore time: 1 s
```

### MongoDB restore (`order_db_drill`, a copy of `order_db`)
```text
0. work on a copy of order_db: order_db_drill
1. backup order_db_drill (mongodump archive)
      72439 bytes; collections: 1
2. disaster: orders deleted by mistake
   deleted: 3 orders
   fingerprint changed
3. restore the backup into a NEW database order_db_restored
4. verify: every collection identical to the backup (indexes included)? YES
   indexes: ["_id_","ix_orders_customer","ix_orders_outbox_pending","ix_orders_status","uq_orders_idempotency_key"]
   restore time: 3 s
```

### Dead-letter redrive
```text
1. incident: a valid command dead-lettered (e.g. the database was down for longer than 5 receives)
   DLQ depth: 1; notifications with this key: 0
2. cause fixed; redrive the DLQ into its source queue
   move task: task-a5db64df-15b0-43dc-bac0-e79fcdc145c…
3. processed: notifications with this key: 1; DLQ depth: 0
4. the same message redriven AGAIN (someone runs the redrive twice)
   notifications with this key: 1 (idempotent: still one); DLQ depth: 0
```

### Rollback (second run)
```text
1. current release is healthy (HTTP 200); keep it as :good (in AWS: the previous task definition revision)
2. deploy a broken release (crashes at startup)
3. work arrives while it is broken
4. detected: readiness HTTP 000, container: Restarting (1) Less than a second ago, last log: bad release: missing configuration
   processed so far: 0 (the message waits in SQS)
5. roll back to :good
   healthy again after 262 s (HTTP 200)
6. the message sent during the incident is processed: 1 notification, 287 s after the rollback began
```
