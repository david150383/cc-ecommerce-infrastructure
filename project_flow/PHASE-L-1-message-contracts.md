# Phase L-1: Message Contracts: Envelope, Commands, Events, Vendoring, Validation

## 1. The envelope: [schemas/common/envelope.v1.schema.json](ecommerce-contracts/schemas/common/envelope.v1.schema.json)

Every SNS/SQS body is one envelope. Line by line:

| Field (all **required**) | Constraint | Purpose | Who relies on it |
|---|---|---|---|
| `messageId` | `uuid` | Unique per message; **reused** when the same message is re-sent | saga `processed_messages`; notification dedupe; FIFO `MessageDeduplicationId` |
| `messageKind` | `event` \| `command` | Routes validation (strict vs tolerant) | consumers' parsers |
| `messageType` | `^[A-Z][A-Za-z0-9]+$` | Which schema; also the SNS **message attribute** filter policies match | every consumer, SNS filters |
| `messageVersion` | integer ≥ 1 | Which version of that type | **nobody at runtime** (L-F2) |
| `producer` | `^ecommerce-[a-z-]+$` | Who sent it | logs, `actor` in Order history |
| `occurredAt` | `date-time` and `pattern: Z$` | UTC only, so there are no timezone bugs | audit |
| `correlationId` | 8–128 chars | One id across a whole business flow (the saga uses `sagaId`; HTTP flows the request's `x-correlation-id`) | tracing across services |
| `causationId` | string or `null` | The message that caused this one (a command's `messageId` → the resulting event) | causal debugging |
| `sagaId` | uuid or `null` | Routes replies to the saga instance | saga `lock(sagaId)` |
| `idempotencyKey` | string or `null`; **`if messageKind = command` then string** (`if/then` at the bottom) | A command must carry a stable key; events never need one | Inventory reservation key, Payment refund key, Order transitions |
| `payload` | `object` | Message-specific; constrained by each message schema | — |

`additionalProperties: false` at the envelope level: nobody can add a top-level field without a contracts change.
Any envelope change is judged in **both** directions by `compat` (everyone reads and writes it).

Stale text: the envelope's `description` still says "COPIED into each producing repository until ecommerce-contracts exists
(Phase 6). Keep copies identical by hand." That's no longer true (P3, but it's a released file, so it needs a patch release).

## 2. A command schema: [RefundRequested v1](ecommerce-contracts/schemas/payment-service/refund-requested.v1.schema.json)

```json
"x-message-kind": "command",
"x-producer": "ecommerce-saga-orchestrator",
"x-consumers": ["ecommerce-payment-service"],
"x-channel": "SQS payment-commands",
"$ref": "../common/envelope.v1.schema.json",
"properties": {
  "messageKind": {"const": "command"}, "messageType": {"const": "RefundRequested"},
  "messageVersion": {"const": 1}, "producer": {"const": "ecommerce-saga-orchestrator"},
  "payload": { "required": ["paymentId","orderId","amount","reason"], "additionalProperties": false,
    "properties": { "paymentId": uuid, "orderId": uuid,
      "amount": {"amountMinor": integer ≥ 0, "currency": "^[A-Z]{3}$"},
      "reason": {"enum": ["OUT_OF_STOCK_AFTER_PAYMENT","LATE_PAYMENT_AFTER_CANCELLATION","CUSTOMER_REQUESTED","ADMIN"]} } } }
```

- **Owner = consumer** (Payment): it lives in `schemas/payment-service/` although the saga sends it. A command is part of
  the **receiver's** API.
- `$ref` + `properties` = "the envelope, **and** these narrower rules". In 2020-12, `$ref` sits beside other
  keywords and both apply.
- `x-*` keywords are a custom **vocabulary** (`ajv.addVocabulary([...])`). Ajv in strict mode would otherwise reject
  unknown keywords. They drive the ownership matrix, AsyncAPI, vendoring and the parsers' "is this addressed to me?" check.
- Money is `amountMinor` (integer) + `currency`. There are no floats anywhere in a contract.
- The `reason` enum doubles as documentation of every refund path in the saga.

## 3. An event schema: [InventoryReserved v1](ecommerce-contracts/schemas/inventory-service/inventory-reserved.v1.schema.json)

Same structure with `x-message-kind: event`, **owner = producer** (Inventory), `x-channel: SNS inventory-events`, payload
`reservationId, orderId, lines, expiresAt` required and `additionalProperties: false`.

Why `additionalProperties: false` on an **event** payload doesn't hurt readers: consumers don't validate events against
this schema (§5). It constrains the **producer** instead: Inventory's own tests check that every event its code writes is
schema-valid ([stock.spec.ts](ecommerce-inventory-service/test/stock.spec.ts) "every event written by a full
reserve/confirm/release/expire/low-stock cycle is schema-valid"), so the producer can't emit an undeclared field.

## 4. Ownership rules and what the contracts tests enforce

From [tests/contracts.test.mjs](ecommerce-contracts/tests/contracts.test.mjs) and the README:
- ONE envelope; every message `$ref`s it. Each (message, version) is unique.
- The folder is the owner: events are under their producer, commands under their consumer. Naming, `$id` and channel must agree.
- Every schema compiles (Ajv 2020, strict); every example validates; no stray examples.
- AsyncAPI is valid 3.0.0 and every payload file it references exists; generated files are current.

`docs/OWNERSHIP.md` is generated from `x-producer` / `x-consumers`. Those lists are **declared by the owner** in the
schema. A service that starts consuming an event must get itself added (a contracts PR, patch bump), or two things
happen: `vendor.mjs` won't give it the schema (it vendors only what a service owns, produces or consumes), and the
owner won't know about it when retiring a version. The vendoring rule nudges teams to declare, which is good.

## 5. Validation at runtime: who checks what

| Side | Messages | How | Effect of failure |
|---|---|---|---|
| **Producer** (any service writing to its outbox) | its own events / the commands it sends | tests validate emitted envelopes against the vendored schemas (auth, inventory, order, payment tests; saga "every command type, from real flows, validates against the vendored (receiver-owned) schema") | CI fails |
| **Command owner** (inventory, order, payment, notification) | commands addressed to it | `commandParser()`: Ajv with the vendored schema, **only** types whose `x-consumers` include this service ([inventory command-schemas.ts](ecommerce-inventory-service/src/messaging/command-schemas.ts), [notification parsers.ts](ecommerce-notification-service/src/messaging/parsers.ts)) | `InvalidCommand` → message **not deleted** → DLQ after 5 receives |
| **Event consumer** (saga, notification) | events from others | envelope only, tolerantly (`z.looseObject` / Zod object without strict), then payload fields **where used** | malformed envelope → DLQ; a missing used field → handler error → retry → DLQ |

That asymmetry is deliberate:
- Events: many readers, one writer. Readers must survive the writer adding fields → **tolerant**.
- Commands: one reader (the owner), several writers. The owner defines exactly what it accepts → **strict**.
  The consequence for evolution: the owner must deploy acceptance of a new field **before** any sender sends it (L-3 §4).

## 6. Consumer-driven checks (what consumers assert about producers)

| Consumer | Test | What it proves | What it doesn't |
|---|---|---|---|
| Saga | [event-schemas.test.ts](ecommerce-saga-orchestrator/tests/event-schemas.test.ts) `RELIES_ON` map: per event, the payload fields the saga uses must be in the producer's **`required`** list | A producer can't make `reservationId` optional (or drop it) without the saga's CI failing at the next re-pin | That the saga's code actually reads only those fields (it's a declared list) |
| Notification | [consumer-contracts.test.ts](ecommerce-notification-service/tests/consumer-contracts.test.ts): every consumed event's **producer example** goes through the real `handleEvent` → `applied`/`ignored` | Real handler + real producer example: the strongest check here (the demo shows it catching `total` → `grandTotal`) | Examples are one sample, so optional/edge fields are not covered |
| Frontend | `contract-check.ts` (16 `Assignable<Published, UiReads>` assertions) | The UI's hand-written types are still provided by the pinned APIs | Runtime responses |

These are **consumer-driven contract tests without a broker**. The consumer runs them against the producer's
published artifacts when it re-pins. The Pact alternative (a broker plus provider verification in the producer's
CI) would catch a break **in the producer's PR**, before release. That is stronger, at the cost of running a Pact Broker.

## 7. Vendoring and the lock: [scripts/vendor.mjs](ecommerce-contracts/scripts/vendor.mjs)

```bash
# run inside ecommerce-contracts
node scripts/vendor.mjs --service saga-orchestrator --into ../ecommerce-saga-orchestrator --version v1.2.0
```

1. `git rev-list -n 1 <version>` resolves the tag to a commit. It reads files **from that commit**
   (`git show <commit>:<path>`), **never from the working tree**, so uncommitted edits can't leak into a pin.
2. It selects the envelope + every message the service **owns, produces or consumes** (frontend: all 7 OpenAPI docs).
3. It **deletes** the target directories and rewrites them (a message no longer used disappears).
4. It writes `contracts.lock.json` (`source`, `version`, `commit`, `service`, `directories`, SHA-256 per file) and copies
   `templates/verify-contracts.mjs` → `scripts/verify-contracts.mjs`.

Each service's test suite runs `verify-contracts.mjs`, which fails on a modified file, a missing file, or an extra file
not from the release. Hand edits are impossible to merge unnoticed.

Caveats:
- `--version` accepts any git ref. The demo vendored `demo/rename-in-place` (a branch), which is useful for experiments, but
  nothing stops a branch pin from being committed. `verify-contracts` checks hashes, not that `version` is a **tag**. The
  nightly E2E ("every service is pinned to a real release") would catch it, if it ran (J-F12).
- The script writes into a **sibling directory** (`--into ../…`): it's a local-machine workflow. With the contracts repo
  pushed (`cc-ecommerce-contracts`), a CI job or bot could open the re-pin PRs instead.
