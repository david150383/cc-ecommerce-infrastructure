# Phase F: SNS/SQS Messaging End to End, and the Notification Service

Read-only. Topology: [messaging/main.tf](ecommerce-infrastructure/terraform/modules/messaging/main.tf) (Phase K-2 §3).
Contracts: Phase L. This phase traces how messages actually move and what consumers do with them.

---

## 1. The concepts, applied to this platform

| Concept | Meaning | Here |
|---|---|---|
| **SNS topic** | publish once, deliver to every subscription | one per producer: `auth/order/inventory/payment/saga-events` |
| **Subscription + filter policy** | which messages a subscriber gets | `messageType` **message attribute**, e.g. saga-inbox ← inventory-events only for the 5 reservation outcomes |
| **Raw message delivery** | the SQS body = the published message (no SNS JSON wrapper) | on: consumers parse the envelope directly |
| **SQS queue** | durable buffer, pull-based, at-least-once | command queues (one consumer each) and inbox queues (fed by SNS) |
| **Long polling** | `ReceiveMessage(WaitTimeSeconds=20)` waits for messages instead of returning empty | queue default 20 s; consumers request 20 s (tests use 1) |
| **Visibility timeout** | a received message is hidden for N s; if not deleted, it reappears | 60 s |
| **Delete after success** | acknowledge = `DeleteMessage` only once the work committed | every consumer |
| **ApproximateReceiveCount / redrive** | each receive increments it; at `maxReceiveCount` SQS moves the message to the DLQ | 5 → `<queue>-dlq` (14-day retention) |
| **Redrive allow policy** | which queue may use a DLQ | only its own main queue |
| **FIFO** | ordered per `MessageGroupId`, dedupe by `MessageDeduplicationId` for 5 min | only `order-commands.fifo` (group = orderId, dedupe id = messageId) |
| **Commands vs events** | "please do X" (one owner, sent to its queue) vs "X happened" (any subscribers, via SNS) | Phase A-6 decision 3 |
| **Outbox** | the message is written in the same DB transaction as the change; a relay publishes it | every producer |
| **Inbox / idempotent consumer** | record processed `messageId`s, or dedupe by business key/state | saga + notification `processed_messages`; inventory/order/payment by keys and state |
| **Poison message** | can never succeed (bad schema, unknown type) | not deleted → DLQ after 5 receives (it isn't deleted early, so it stays inspectable) |

**Why at-least-once is unavoidable:** a consumer can crash after doing the work but before `DeleteMessage`. A relay can crash
after `Publish` but before marking the row. The network can lose the ack of a successful publish. Each of these produces a
duplicate, and none can be prevented by SNS/SQS. "Exactly-once" therefore only exists as **exactly-once effect**, built
from idempotent consumers. That's why every handler here either dedupes by `messageId` or is naturally idempotent by state.

## 2. Every message, traced

| Message | Producer → channel | Consumer(s) (queue) | Side effect |
|---|---|---|---|
| `UserRegistered` | auth → `auth-events` | notification (`notification-inbox`) | upsert `recipients` (email, name) + welcome email |
| `UserEmailVerified` | auth → `auth-events` | notification | mark the recipient verified |
| `OrderCreated` | order → `order-events` | **none** | — |
| `OrderConfirmed` | order → `order-events` | saga (`saga-inbox`): → COMPLETED; notification: confirmation email/SMS | |
| `OrderCancelled` | order → `order-events` | saga: compensation tick / customer cancelled; notification: cancellation email | |
| `OrderCancellationRequested` | order → `order-events` | saga: paid-order refund flow | |
| `OrderStatusChanged` | order → `order-events` | notification: only SHIPPED/DELIVERED become emails | |
| `InventoryReserved` / `…Failed` / `…Confirmed` / `…Released` / `InventoryReturned` | inventory → `inventory-events` | saga | state transitions (A-2) |
| `InventoryLowStock` | inventory → `inventory-events` | notification: an alert email to `ADMIN_ALERT_EMAILS` | |
| `PaymentInitiated` | payment → `payment-events` | **none** | — |
| `PaymentSucceeded` | payment → `payment-events` | saga | confirm inventory, or refund if late |
| `PaymentFailed` | payment → `payment-events` | saga: compensate; notification: **deliberately silent** (the OrderCancelled email covers it) | |
| `RefundSucceeded` | payment → `payment-events` | saga: compensation tick; notification: refund email | |
| `RefundFailed` | payment → `payment-events` | saga: → MANUAL_REVIEW | |
| `CheckoutCompleted` / `CheckoutFailed` / `SagaManualReviewRequired` | saga → `saga-events` | **none** (M-F1) | — |
| `InventoryReservation{,Confirm,Release}Requested`, `InventoryReturnRequested` | saga → `inventory-commands` | inventory | reserve / confirm / release / return |
| `OrderStatusTransitionRequested` | saga → `order-commands.fifo` | order | status change |
| `RefundRequested` | saga → `payment-commands` | payment | refund |
| `NotificationRequested` | **saga only** in the code (`order.under-review`) → `notification-commands` | notification | email to the customer |

Four messages have **no subscriber** today. That's harmless (SNS drops them), but `SagaManualReviewRequired` *should* have one (N-03).

**Declared vs actual producers (CONFIRMED by grep):** the contract lists saga, order **and payment** as producers of
`NotificationRequested`, and IAM grants order and payment `sqs:SendMessage` on `notification-commands`
([messaging/main.tf:61-63](ecommerce-infrastructure/terraform/modules/messaging/main.tf#L61-L63)). Only
[decide.ts](ecommerce-saga-orchestrator/src/saga/decide.ts) sends it. Least privilege says remove the unused grants (or
keep them deliberately for planned use and say so). It's a P3 hygiene item (N-31).

### Envelope fields in motion (one example)
Saga sends `InventoryReservationRequested {messageId: A, correlationId: <sagaId>, causationId: null, sagaId, idempotencyKey: "<sagaId>:reserve"}`
→ Inventory writes `InventoryReserved {messageId: B, correlationId: <sagaId>, causationId: A, sagaId}`
→ the saga applies B (dedupes on B), and its next command C has `causationId: B`. Following `causationId` reconstructs the chain.

## 3. Consumer loop anatomy (same shape in every service)

[notification message-consumer.ts](ecommerce-notification-service/src/messaging/message-consumer.ts) (inventory, order and payment are identical):
```
loop until aborted:
  ReceiveMessage(MaxNumberOfMessages 10, WaitTimeSeconds 20, ApproximateReceiveCount)
  for each message (sequentially):
    parse (schema / envelope)  → fail: log error, DO NOT delete (→ DLQ after 5 receives)
    handler.handle(message)    → InvalidMessage: log error, don't delete; other error: log warn, don't delete (retry)
    DeleteMessage              → only after the handler's transaction committed
  on receive error: log, back off 2 s
stop(): abort the long poll, await the loop
```
Design choices and their consequences:
- **Sequential processing per batch**: simple and ordered, but a slow batch can exceed the 60 s visibility timeout (K-2 §3.1).
- **No early delete of poison messages**: they reach the DLQ with their receive history intact, ready for the runbook.
- **No `ChangeMessageVisibility` extension** (the docs claim one, the code has none: N-25).
- The `receiveCount` is logged, so you can see "attempt 4 of 5" in the logs before a DLQ move.

## 4. The Notification Service in depth

### 4.1 Two inputs, one output
- **Events** (`notification-inbox`): tolerant envelope parse, then per-type Zod payload parsing of **only the fields used**
  ([notification-service.ts EVENT_PAYLOADS](ecommerce-notification-service/src/notifications/notification-service.ts)).
- **Commands** (`notification-commands`): strict Ajv validation against the owned `NotificationRequested` schema, plus rules:
  the template must exist, must not be a `security` template (secrets never go through queues), the channel must be supported,
  and an `idempotencyKey` is required.
- **Transactional HTTP** (`POST /internal/v1/notifications/transactional`, service role + `TRANSACTIONAL_CALLERS = auth`): secret-bearing mail.
- **Output:** a `notifications` row per (dedupe key, channel), delivered by a worker.

### 4.2 Ingest is transactional and idempotent
`handleEvent` = one transaction: `processed_messages` insert (`ON CONFLICT DO NOTHING` → "duplicate") + the side effects
(recipient upserts, `INSERT notifications … ON CONFLICT (dedupe_key, channel) DO NOTHING`). Dedupe keys are **business
keys** (`order-confirmed:<orderId>`, `refund:<refundId>`, `welcome:<userId>`), so even a re-emitted event with a *new*
messageId (Phase L-3 §5) doesn't send a second email.

### 4.3 The delivery worker (an outbox for emails)
`deliverDue` claims due rows with **`UPDATE … WHERE id IN (SELECT … FOR UPDATE SKIP LOCKED) RETURNING *`** and sets
`SENDING`, `attempts + 1` and a lease. Several instances never take the same row, and a row whose worker died becomes due when its lease expires.
`deliverOne`:
1. Resolve the address from the **recipients projection** (built from Auth events). Missing email → **retry**, because an order
   email can overtake `UserRegistered` (events from different topics aren't ordered).
2. Check preferences by template category (`security`/`admin` ignore opt-outs; `account` = email only; `order_updates` per
   channel; `marketing` opt-in). Opted out → `SKIPPED`.
3. Render **plain-text** templates ([templates.ts](ecommerce-notification-service/src/templates/templates.ts)): no HTML means no
   injection from data such as a customer's name.
4. Send. SMTP **5xx = permanent** (`PermanentDeliveryError` → FAILED); 4xx/network = transient → `retryOrFail` with
   **full-jitter exponential backoff** (`random × min(cap, base·2^(attempt−1))`, the AWS-recommended form that avoids
   synchronized retry storms), up to `maxAttempts`.
5. Record `SENT` **outside** the send's try/catch. If recording fails after a successful send, it isn't retried as a failure.
   The stable `Message-ID: <notificationId@domain>` lets mail systems recognize the rare repeat (after a lease expiry).

### 4.4 Secret-bearing mail (password reset, verification)
`sendTransactional`: claim a row (`in_memory_only = true`, `SENDING`, a 30 s lease) keyed `transactional:<idempotencyKey>`,
then render and send **in the request** with a few quick retries. The secret URL is **never stored, logged or queued**: the row
holds template, recipient and outcome only (tests scan the DB and logs for the token). A repeat after success → `replayed`, with nothing
sent. In progress → 409. Total failure → 503, and the user asks for a new link. An operator **can't** re-send these
(`NOT_RETRYABLE`), by design.

### 4.5 DLQ monitor ([dlq-monitor.ts](ecommerce-notification-service/src/messaging/dlq-monitor.ts))
Periodically reads `ApproximateNumberOfMessages` of the configured DLQs and logs at **error** level when any is non-empty.
`peek` receives with a 5 s visibility and immediately resets it to 0, so the message stays in the DLQ, unconsumed. In AWS these calls are
currently **not permitted** by IAM (N-05). There's no metric yet, so alerting relies on the CloudWatch DLQ alarms (N-01).

### 4.6 Tests ([tests/](ecommerce-notification-service/tests))
`delivery.test.ts` (backoff, permanent vs transient, lease expiry, SKIPPED by preference, recipient-unknown retry),
`consumer-contracts.test.ts` (every producer example through the real handler), `api.test.ts` (preferences, history,
admin, the secret never stored), `messaging.test.ts` (both queues + DLQ over Floci), `templates.test.ts`.

## 5. Troubleshooting messages (see M-3 §3 for commands)
- Event emitted but no email: is the notification row there? `SKIPPED` (preferences)? `QUEUED` with
  `last_error = RECIPIENT_UNKNOWN` (no `UserRegistered` seen for that user)? `FAILED` (SMTP 5xx, or attempts exhausted)?
- Duplicate emails: check `dedupe_key` (should prevent them); otherwise a lease expiry during a slow SMTP send. Check `delivery_attempts`.
- Nothing arrives at the inbox: is the type in the subscription's filter policy? (`aws sns get-subscription-attributes … FilterPolicy`).

## 6. Alternatives and trade-offs
- SNS+SQS (used) vs EventBridge (content-based routing on any field, schema registry, archive/replay) vs Kafka/MSK
  (ordered partitions, replay by offset, consumer groups). SNS+SQS is the cheapest and simplest at this scale. Replay
  needs the outbox tables or DLQ redrive.
- Per-message `processed_messages` (saga, notification) vs business-key dedupe (inventory, payment): the first is generic;
  the second needs no extra table and also catches re-emits with new ids. Notification does **both**.
- In-app delivery queue (the `notifications` table) vs SES's own queueing: owning the queue gives preferences, history,
  retries and admin retry in one place.

## Exercises and acceptance criteria (Phase F)
1. For `OrderConfirmed`, list every hop from Order's `findOneAndUpdate` to the customer's inbox, naming each table, topic,
   subscription, queue and dedupe key.
2. A consumer crashes after committing its transaction but before `DeleteMessage`. Walk through what happens for the saga and for notification.
3. Why is `PaymentFailed` silent in Notification while `OrderCancelled` isn't?
4. Why must password-reset mail never be sent through `notification-commands`?

**You're done with Phase F when** you can explain visibility timeout, long polling, receive count and DLQ with this
platform's numbers, trace any message in §2 end to end, and explain why "exactly-once" here means idempotent effects.
