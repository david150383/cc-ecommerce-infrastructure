# Messaging Topology (SNS + SQS)

The topology is implemented in [`terraform/modules/messaging`](../../terraform/modules/messaging).
This document explains *why* it looks the way it does.

## Commands vs events map to different AWS primitives

| | Commands | Events |
|---|---|---|
| Meaning | "Please do X" | "X happened" |
| Number of consumers | Exactly one: the owner of the operation | Zero or more, unknown to the producer |
| AWS primitive | **SQS queue, sent to directly** (`SendMessage`) | **SNS topic**, fanned out to one SQS queue per subscribing service |
| Schema owner | The consumer | The producer |
| Naming | Imperative or "...Requested" | Past tense |

Using SNS for commands would hide the single-owner relationship and let
unrelated services start acting on requests meant for someone else.

## Resource names

`{env}-ecommerce-{name}`, e.g. `dev-ecommerce-order-events`,
`prod-ecommerce-inventory-commands-dlq`.

## SNS topics (standard)

| Topic | Producer | Messages |
|---|---|---|
| `auth-events` | Auth | `UserRegistered`, `UserEmailVerified` |
| `order-events` | Order | `OrderCreated`, `OrderConfirmed`, `OrderCancelled`, `OrderStatusChanged` |
| `inventory-events` | Inventory | `InventoryReserved`, `InventoryReservationFailed`, `InventoryReservationConfirmed`, `InventoryReservationReleased`, `InventoryLowStock` |
| `payment-events` | Payment | `PaymentInitiated`, `PaymentSucceeded`, `PaymentFailed`, `RefundSucceeded`, `RefundFailed` |
| `saga-events` | Saga | `CheckoutCompleted`, `CheckoutFailed`, `SagaManualReviewRequired` |

## SQS command queues (one consumer each)

| Queue | Consumer | Commands | Sent by |
|---|---|---|---|
| `inventory-commands` | Inventory | `InventoryReservationRequested`, `InventoryReservationConfirmRequested`, `InventoryReservationReleaseRequested` | Saga |
| `order-commands` | Order | `OrderStatusTransitionRequested` | Saga |
| `payment-commands` | Payment | `RefundRequested` | Saga |
| `notification-commands` | Notification | `NotificationRequested` | Saga, Order, Payment |

## SQS inbox queues (subscribed to topics)

| Queue | Consumer | Subscribed topics | Filter policy (`messageType`) |
|---|---|---|---|
| `saga-inbox` | Saga | `inventory-events`, `payment-events`, `order-events` | Inventory: all reservation outcomes. Payment: `PaymentSucceeded`, `PaymentFailed`, `RefundSucceeded`, `RefundFailed`. Order: `OrderConfirmed`, `OrderCancelled` |
| `notification-inbox` | Notification | `auth-events`, `order-events`, `payment-events`, `inventory-events` | Auth: `UserRegistered`, `UserEmailVerified`. Order: `OrderConfirmed`, `OrderCancelled`, `OrderStatusChanged`. Payment: `PaymentFailed`, `RefundSucceeded`. Inventory: `InventoryLowStock` |

Subscriptions use **raw message delivery**, so the SQS body is exactly the
envelope JSON (no SNS wrapper). `messageType` is also sent as an SNS message
attribute, so filter policies can match on it.

## Queue settings

| Setting | Value | Why |
|---|---|---|
| Type | Standard (not FIFO) | Higher throughput, and consumers are idempotent and order-tolerant anyway |
| Visibility timeout | 60s | ≥ 6× the expected handler time. The consumer extends it for slow work |
| Receive wait time | 20s | Long polling: fewer empty receives, lower cost |
| Message retention | 4 days (queue), 14 days (DLQ) | Time to fix and redrive |
| Redrive policy | `maxReceiveCount = 5` → `<queue>-dlq` | Poison messages stop blocking retries |
| Encryption | SSE-SQS / SSE-SNS with AWS-managed key (KMS CMK in prod) | Encrypted at rest |
| Access | Queue policy allows `sns:Publish` only from the subscribed topic ARNs. IAM roles grant each service only the actions listed below | Least privilege |

## IAM permissions per service

| Service | Publish to | Send to | Consume from |
|---|---|---|---|
| Auth | `auth-events` | — | — |
| Order | `order-events` | `notification-commands` | `order-commands` |
| Inventory | `inventory-events` | — | `inventory-commands` |
| Payment | `payment-events` | `notification-commands` | `payment-commands` |
| Saga | `saga-events` | `inventory-commands`, `order-commands`, `payment-commands`, `notification-commands` | `saga-inbox` |
| Notification | — | — | `notification-commands`, `notification-inbox` |

## Monitoring

- CloudWatch alarm: `ApproximateNumberOfMessagesVisible > 0` on every DLQ.
- CloudWatch alarm: `ApproximateAgeOfOldestMessage > 300s` on every main queue
  (a sign the consumer is stuck).
