# Phase L-3: Compatibility Rules and Safe Evolution

## 1. The core idea: judge every change from the side that did *not* make it

[lib/compat.mjs](ecommerce-contracts/lib/compat.mjs) assigns each contract part a **direction**:

| Direction | Applies to | Who writes / who reads | What breaks the other side |
|---|---|---|---|
| `read` | events, API **responses** | owner writes, others read | **loosening**: a field removed or made optional, a type widened, an enum value added (warning), a format/pattern removed (warning) |
| `write` | commands, API **requests** (body, query, path, headers) | others write, owner reads | **tightening**: a new required field, an enum value removed, a stricter pattern/length/format, `additionalProperties: false` added |
| both | the envelope | everyone | any non-safe change in either direction |

```js
const onLoosen  = (dir) => (dir === "read"  ? "breaking" : "safe");   // line 18
const onTighten = (dir) => (dir === "write" ? "breaking" : "safe");   // line 19
```

## 2. Rule table (what `compareSchemas` reports)

| Change | Event / response (`read`) | Command / request (`write`) | Code |
|---|---|---|---|
| Property removed | **breaking** | safe, unless the owner has `additionalProperties: false` (then writers still sending it get rejected → **breaking**) | lines 140–146 |
| Required → optional | **breaking** (readers may now see it missing) | safe | 148 |
| Optional → required | safe | **breaking** | 149 |
| New **required** property | safe ("new required property") | **breaking** ("new REQUIRED property") | 155 |
| New optional property | safe | safe | 156 |
| Type widened (`string` → `string \| null`, `integer` → `number`) | **breaking** | safe | 80–91 |
| Type narrowed | safe | **breaking** | |
| `const` changed (e.g. `messageVersion`) | **breaking** both ways | | 99–101 |
| Enum value added | **warning** | safe | 111 |
| Enum value removed | safe | **breaking** | 112 |
| `format` / `pattern` added | safe | **breaking** | 117–122 |
| `format` / `pattern` removed | warning | safe | |
| min bigger / max smaller (tightened) | safe | **breaking** | 123–132 |
| Loosened limits | warning | safe | |
| `additionalProperties: false` added | safe | **breaking** | 159 |
| `anyOf`/`oneOf`/`allOf` with a different number of alternatives | **warning: "review by hand"** | same | 165–172 |
| Message removed / kind changed / channel changed | **breaking** | | 184–195 |
| Message added | safe | | 190 |
| OpenAPI: operation removed, success response removed, path parameter removed, parameter now required, request body now required | **breaking** | | 246–289 |
| Consumers list changed | metadata (patch) | | 198–200 |

Recursive schemas (Product's category tree) terminate via a per-path `$ref` pair set (lines 66–70; commit
"compat: terminate on recursive schemas").

## 3. From findings to a required version bump

```js
requiredBump(findings): breaking → "major"; any non-metadata change → "minor"; metadata only → "patch"   // 303–307
```
`scripts/compat.mjs` compares `requiredBump` with the actual `package.json` bump since the last tag and **exits 1 if it is
too small**. "Warning" counts as a contract change (minor) but never blocks a minor release. A human must read warnings.

Why the enum-added case is only a *warning* for readers: tolerant readers ignore unknown values, but code like
`switch (status) { … default: throw }` or an exhaustive TypeScript union breaks. Example: adding a new `OrderStatus` to
`OrderStatusChanged.toStatus`. Notification renders a status-change email. Does it handle an unknown status gracefully?
That's exactly what the "review" means.

## 4. How a change actually ships (expand → migrate → contract), and the deploy order

### Events (owner = producer)

| Step | Producer (e.g. Order) | Consumers (saga, notification) |
|---|---|---|
| **Additive** (new optional field) | release a minor, re-pin, emit the field | nothing required; re-pin when they want to use it |
| **Breaking**: expand | add `order-confirmed.v2.schema.json` (`messageVersion: 2`) beside v1, release a **minor**, emit **both** v1 and v2 | — |
| migrate | — | each re-pins and switches to v2 at its own pace |
| contract | stop emitting v1 when OWNERSHIP.md shows no v1 consumer; remove v1 in a **major** | — |

### Commands (owner = consumer)

| Step | Owner (e.g. Payment for `RefundRequested`) | Senders (saga) |
|---|---|---|
| New **optional** field | 1. release + re-pin + **deploy** the parser that accepts it | 2. only then re-pin and send it |
| New **required** field | breaking: add `v2` command beside v1; the owner accepts both, deployed **first** | send v2; the owner removes v1 later |

**Why the order matters here (L-F4, CONFIRMED by code):** command parsers validate with `additionalProperties: false`
against the **owner's pinned** schema. Say the saga re-pins a release in which `RefundRequested.payload` gained an optional
`note`, and starts sending it before Payment has deployed that release. Payment's parser rejects the command
(`InvalidCommand`), the message is never deleted, and after 5 receives it's in the DLQ. Refunds stop. `compat` (correctly)
calls the schema change "safe". The **rollout** is what isn't safe. VERSIONING.md doesn't state the deploy-order rule.
Add it, or make owners ignore unknown payload fields for commands they own (trading strictness for rollout safety).

### HTTP

| Change | Order |
|---|---|
| New optional response field | server first; clients whenever |
| New optional request field | server first (it must accept it), then clients send |
| Breaking | `/api/v2/...` beside v1; server ships both; clients migrate; v1 removed after a deprecation window |

### Expand-and-contract for **databases** (same pattern, a different contract)

The "previous release must work with the new schema" rule (deployment.md, runbooks.md §3) is the same idea applied to tables.
An example built from this codebase (hypothetical): renaming `payments.provider_payment_ref` → `provider_charge_id`:
1. **Expand**: migration adds `provider_charge_id` (nullable); code writes both, reads the old one.
2. **Migrate**: backfill `UPDATE payments SET provider_charge_id = provider_payment_ref WHERE provider_charge_id IS NULL` in batches; deploy code that reads the new one.
3. **Contract**: a later release drops `provider_payment_ref`, only after no running version reads it.
Doing it in one migration breaks the old tasks still serving during the rolling deploy (and after an automatic rollback).

## 5. The `messageVersion` gap (L-F2, CONFIRMED by code)

The expand step for events says the producer emits **both** v1 and v2 of `OrderConfirmed`. But:
- SNS messages carry only the `messageType` attribute ([saga outbox-relay.ts:97](ecommerce-saga-orchestrator/src/messaging/outbox-relay.ts#L97) and the other relays).
- Filter policies match only `messageType` ([messaging/main.tf](ecommerce-infrastructure/terraform/modules/messaging/main.tf) `filter_policy = { messageType = [...] }`).
- No consumer reads `messageVersion` (grep over all `src/`: it appears only in type declarations).

So every subscriber receives **both** copies and treats v2 as if it were v1. In the documented demo (`total` → `grandTotal`),
Notification's handler would fail on every v2 copy (missing `total`) → retries → DLQ, while v1 copies succeed. The saga
would see two `OrderConfirmed`s (the second ignored by state, so harmless there). The procedure is sound on paper, but the
runtime can't express it yet.

Fix before the first v2: publish `messageVersion` as an SNS attribute too; add it to each subscription's filter policy
(`{ messageType: ["OrderConfirmed"], messageVersion: [1] }`, changed to `[2]` when a consumer migrates); make consumers
dispatch on `(messageType, messageVersion)` and explicitly ack+log versions they don't handle. Add a contracts rule: "a v2
message requires a matching filter-policy change", checked in the infra repo.

## 6. What compatibility checking cannot see

| Blind spot | Example here | Mitigation |
|---|---|---|
| Semantics | `amountMinor` starting to mean "including tax" when it didn't; `occurredAt` meaning commit time vs request time | descriptions in schemas; reviews; consumer tests with real examples (Notification's pattern) |
| Error responses and codes | removing `IDEMPOTENCY_KEY_REUSED` | enum of codes per operation |
| Security changes | an operation now `admin`-only | compare `security` blocks; contract tests with tokens |
| Behavioral/ordering promises | "commands for one order arrive in order" (FIFO) | documented in schema `description` + AsyncAPI channel bindings; infra tests |
| Runtime conformance | a producer emitting what the schema doesn't say | producer tests validating emitted messages (present); response validation (only Inventory) |
| Undeclared consumers | a service reading an event without being in `x-consumers` | vendoring nudges declaration; can't be enforced |
| Rollout order | L-F4 | deploy-order rule + owner-first rollouts |

## 7. AsyncAPI: what it adds here

[asyncapi/asyncapi.json](ecommerce-contracts/asyncapi/asyncapi.json) (3.0.0) is generated by
[scripts/build.mjs](ecommerce-contracts/scripts/build.mjs): one channel per topic/queue (9), `send`/`receive` operations per
service (57), messages by `NameV<version>`, payloads referencing the JSON Schema files
(`schemaFormat: application/schema+json;version=2020-12`). It's a **view**, not a source of truth. It's useful for
browsing (AsyncAPI Studio) and for generating docs. It doesn't yet carry SNS/SQS **bindings** (FIFO group id, filter
attributes), which would be the place to document L-F2's `messageVersion` attribute.
