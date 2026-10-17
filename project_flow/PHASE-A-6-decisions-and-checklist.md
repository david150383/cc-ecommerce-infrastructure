# Phase A.6: The Five Most Important Architectural Decisions, Learning Checklist, Phase A Wrap-up

---

## Decision 1: An orchestrated saga whose rules are one pure function

**What it is.** One service (the saga orchestrator) drives checkout. All its rules are in
`decide(saga, input, now, policy)`, which returns a `Decision` (new state, patch, commands, events, deadline)
without doing I/O ([decide.ts:28](ecommerce-saga-orchestrator/src/saga/decide.ts#L28)). The engine applies the
decision in one DB transaction.

**Why this project needs it.** Checkout spans three databases (orders in Mongo, stock and payments in two Postgres
DBs) plus Stripe. No transaction can cover them, so each step needs a compensating action, and someone has to own
the timeouts.

**How it works.** Input (an event, timeout, sync-call result, or operator action) → `lock` the saga row (`FOR UPDATE`)
→ dedupe `messageId` → `decide` → `apply` (UPDATE state + `version+1`, insert `saga_steps`, insert outbox rows) →
commit → the relay publishes. Every waiting state sets `deadline_at`, so the timer loop is also crash recovery.

**Alternatives.**
- *Choreography* (services react to each other's events). Coupling is lower, but nobody owns "where is checkout X?", and
  timeouts and compensation get scattered. That fits short flows with 2–3 steps.
- *Workflow engines* (Temporal, AWS Step Functions). Durable timers, retries and history come for free, at the cost of
  a new platform to run or pay for. They are worth it when there are many long workflows.
- *2PC*. SQS and Stripe can't take part, and it couples availability.

**What not to do.** Don't call HTTP inside the DB transaction (the code explicitly doesn't,
[engine.ts:120-138](ecommerce-saga-orchestrator/src/saga/engine.ts#L120-L138)). Don't treat "command sent" as
success. Don't throw on unexpected events: record and ignore them, because late and duplicate events are normal.

**Interview check.**
- *Why does `runSyncStep` compare `version` after the HTTP call?* The saga may have moved on (for example, the
  customer cancelled) while the call ran. Applying a stale result would resurrect a cancelled checkout.
- *Why is a refund not a rollback?* It is a new money movement that can fail, take days, or need a human. The
  original charge still happened.

---

## Decision 2: Transactional outbox everywhere + idempotent consumers that "re-answer"

**What it is.** No service publishes during a request. It writes the message into its own DB (outbox table, or the
`outbox[]` array inside the Mongo order) in the same transaction as the state change. A relay publishes later.
Consumers delete an SQS message only after success. A duplicate command is not re-executed, but its **result event
is emitted again** ([inventory-command-handler.ts:7-10](ecommerce-inventory-service/src/messaging/inventory-command-handler.ts#L7-L10)).

**Why.** Without it you get the dual-write problem: "DB committed, process died, event never sent" (lost event)
or "event sent, DB rolled back" (phantom event). SQS is at-least-once, so duplicates **will** arrive.

**Where.** Relays: [saga](ecommerce-saga-orchestrator/src/messaging/outbox-relay.ts),
[inventory](ecommerce-inventory-service/src/messaging/outbox-relay.ts),
[order (per-document lease)](ecommerce-order-service/src/messaging/outbox-relay.ts), plus auth and payment. Inbox dedupe:
saga `processed_messages`; notification `processed_messages`; inventory/payment/order dedupe on business keys and state.

**Alternatives.** CDC (Debezium reading the WAL / Mongo change streams): no polling and lower latency, but Kafka
Connect and friends have to be operated. Or "publish then commit" with reconciliation, which is simpler and loses
messages.

**What not to do.** Don't assume exactly-once. Don't let one bad row block the queue (see P1-2). Don't dedupe only by
`messageId` when a producer can re-emit with a new id; dedupe by **state** too (the saga does,
[decide.ts:280](ecommerce-saga-orchestrator/src/saga/decide.ts#L280)).

**Interview check.** *A consumer processed a message but crashed before `DeleteMessage`. What happens?* After the
visibility timeout it is delivered again. The handler sees the existing reservation or refund (same idempotency key),
does no new work, and re-emits the result event.

---

## Decision 3: Commands go to SQS queues, events fan out through SNS; FIFO only where order matters

**What it is.** A command ("please reserve") has exactly one owner, so it is sent straight to that owner's queue,
and the **consumer** owns its schema. An event ("reserved") goes to the producer's SNS topic and fans out by filter
policy to subscriber inboxes, and the **producer** owns its schema. Only `order-commands` is FIFO, with
`MessageGroupId = orderId` ([messaging-topology.md](ecommerce-infrastructure/docs/architecture/messaging-topology.md)).

**Why FIFO only there.** The Order state machine rejects out-of-order transitions (`PAYMENT_PENDING` before
`INVENTORY_RESERVED`). The other consumers are order-tolerant, and standard queues are cheaper and faster.

**Trade-offs.** A FIFO group blocks on a failing message, which is why Order **acks** invalid transitions instead of
retrying ([order-command-handler.ts:29-33](ecommerce-order-service/src/messaging/order-command-handler.ts#L29-L33)).
The producer must also preserve order, which is why the saga relay never publishes a saga's newer row before its
older one.

**Alternatives.** EventBridge (richer routing, schema registry, lower throughput per bus), Kafka/MSK (ordering per
partition, replay, heavier to operate).

**Interview check.** *Why not use SNS for commands too?* Any service could subscribe and start acting on requests
meant for someone else, and the single-owner relationship would be invisible.

---

## Decision 4: Database per service, with deliberately different data-access styles

**What it is.** Seven private databases with one role each. Auth uses Prisma, Product SQLAlchemy + Alembic,
Inventory TypeORM, Order Mongoose, and Payment/Saga/Notification raw SQL through `pg`.

**Why.** Ownership: nobody can join across services, so data needed elsewhere travels as API snapshots (Order
copies names and prices) or event projections (Notification's `recipients` table). The raw-SQL choice for the
correctness-critical services makes `FOR UPDATE SKIP LOCKED`, advisory locks and CHECK constraints explicit
instead of hidden behind an ORM.

**Is the diversity justified?** As a learning platform, yes: you see five migration tools and two DB models. As a
real team, it is an **operational cost**: five migration workflows in CI, five sets of footguns, harder on-call. A
production team would usually standardize on one ORM-or-SQL style per language. Don't replace what works now; just
know the cost.

**What not to do.** Don't share a DB user across services. Don't run migrations at startup (the project doesn't).
Don't drop a column before every running version stops reading it (expand → migrate → contract; Phase L).

**Interview check.** *Why does Order embed its outbox in the order document?* MongoDB is atomic per document, so
status + history + pending events change in ONE `findOneAndUpdate`. No multi-document transaction and no replica
set are needed.

---

## Decision 5: A separate contracts repo with vendored, hash-locked, compatibility-checked releases

**What it is.** `ecommerce-contracts` holds 28 message JSON Schemas + the envelope + OpenAPI copies + generated AsyncAPI.
Services **vendor** a tagged release into `events/` (frontend: `contracts/openapi`) and commit
`contracts.lock.json` with SHA-256 per file. A test fails if a vendored file is hand-edited. `npm run compat`
judges every change **from the reader's side** and enforces the semver bump
([VERSIONING.md](ecommerce-contracts/VERSIONING.md), [lib/compat.mjs](ecommerce-contracts/lib/compat.mjs)).

**Why.** Before Phase 6 the envelope was copied into six repos by hand and drifted. Independent deployment requires
that a producer can't silently break a consumer.

**How consumers use it.** Command parsers accept only commands whose schema lists this service in `x-consumers`
([command-schemas.ts:20-23](ecommerce-inventory-service/src/messaging/command-schemas.ts#L20-L23)). The saga tests
that every command it builds validates against the **receiver's** schema. The frontend regenerates types from the
pinned OpenAPI and fails CI on any diff.

**Alternatives.** A schema registry (Confluent/Glue) for runtime enforcement, or Pact consumer-driven contract
tests. Pact is more precise about what each consumer really uses, but needs a broker.

**What not to do.** Don't edit vendored files. Don't make breaking changes in place: add `v2` beside `v1`. Don't
expect pins to be equal across repos (today they range from v1.0.0 to v1.3.0, by design).

**Interview check.** *Adding a required field to an event payload: breaking or not?* Not breaking for readers
(tolerant readers ignore it). Adding a required field to a **command** payload is breaking, because existing senders
don't send it.

---

## Learning checklist (based on this codebase)

Tick an item when you can explain it **without notes** and point to the file.

### Phase B: Git, structure, configuration
- [ ] Why `phase7` ≠ `main` ≠ `origin/main`, and what merging and pushing would trigger
- [ ] How each service validates config at boot (`src/config/env.ts`, `app/config.py`) and fails fast
- [ ] `package-lock.json` / `requirements.txt` pinning, `.nvmrc`, `.python-version`
### Phase C: Auth + Product
- [ ] Argon2id parameters and the dummy-hash timing defense ([password.ts](ecommerce-auth-service/src/security/password.ts))
- [ ] Refresh rotation + reuse detection ([auth.service.ts:196-233](ecommerce-auth-service/src/modules/auth/auth.service.ts#L196-L233)) and the frontend's Web Locks
- [ ] Cookie layout: HttpOnly refresh cookie scoped to `/api/v1/auth`, readable CSRF cookie, `SameSite=Strict`
- [ ] JWKS verification and per-target audience service tokens; `TRUST_PROXY_HOPS=2`
- [ ] Product search: GIN full-text + `pg_trgm`; the internal price-lookup
### Phase D: Inventory + Order
- [ ] The single-statement reservation and why SKU order prevents deadlocks
- [ ] Reservation lifecycle `ACTIVE → CONFIRMED/RELEASED/EXPIRED/REJECTED → RETURNED`
- [ ] Order transition table and CAS on `(status, version)`
### Phase E: Payment
- [ ] Webhook verify → dedupe → apply in one TX; why the raw body
- [ ] "Money truth wins" and late-payment refunds; refund caps; reconciliation
### Phase F: SNS/SQS + Notification
- [ ] Visibility timeout, long polling, `maxReceiveCount=5` → DLQ, raw delivery, filter policies
- [ ] Why secret-bearing mail is synchronous HTTP, never a queue
### Phase G: Saga
- [ ] Every row of the failure table in PHASE-A-2, from memory
- [ ] Leases, `claimDue … SKIP LOCKED`, startup drain
### Phase H: Frontend
- [ ] Idempotency key per checkout attempt in `sessionStorage`; `safePaymentUrl`
### Phase I: Docker
- [ ] Multi-stage targets `runtime` / `migrate`; build args vs runtime env
### Phase J: CI/CD
- [ ] Every step of every workflow; P1-5 and P1-6
### Phase K: Terraform / AWS
- [ ] The `stack` module, OIDC trust conditions, `ignore_changes` (P1-4), alarm KMS (P1-1)
### Phase L: Contracts
- [ ] Run `npm run compat` and read [breaking-change-demo.md](ecommerce-contracts/docs/breaking-change-demo.md)
### Phase M–N: Integration, observability, backlog
- [ ] Trace one checkout by `correlationId` across all service logs

---

## Phase A summary

**Topics covered:** system architecture, repository responsibilities, sync/async dependencies, data ownership,
the real saga state machine and failure paths, the local Docker topology, the workflow and command inventory,
preliminary risks, and the five key decisions.

**Files examined (main ones):** saga `decide.ts`, `engine.ts`, `repository.ts`, `outbox-relay.ts`,
`inbox-consumer.ts`; inventory `reservation.service.ts`, `inventory-command-handler.ts`, `command-consumer.ts`,
`outbox-relay.ts`, the initial migration; order `order.service.ts`, `state-machine.ts`, `order-command-handler.ts`,
`outbox-relay.ts`; payment `payment-service.ts`, `signature.ts`, `routes.ts`, `refund-command-handler.ts`, the
migration; auth `token-service.ts`, `password.ts`, `cookies.ts`, `csrf.ts`, `rate-limit.ts`, `service-token.ts`,
`auth.service.ts` (refresh); frontend `http.ts`, `session.ts`, `checkout.ts`; all 21 workflows; `compose.yaml`;
Dockerfiles; Terraform `stack`, `service`, `platform`, `messaging`, `github-oidc`, `data`; all architecture docs.

**Commands executed (read-only):** `ls`, `find | wc -l`, `git log/branch/status/rev-list/remote/ls-tree/tag`,
`cat`/`sed`/`grep`, `diff` between generated workflows, `node -e` to read `package.json`/OpenAPI files.
**Not executed:** any test, build, compose, terraform or AWS command.

**Confirmed issues:** P1-1 … P1-5, P2-1 … P2-12 (PHASE-A-5). **Plausible:** P1-6, P2-3.

### Hands-on exercises (none of these change a repository)

1. **Read the saga in the DB.** Start infrastructure + the apps profile, run one checkout in the UI, then
   `docker compose exec postgres psql -U saga_svc -d saga_db -c "SELECT from_state, to_state, trigger, at FROM saga_steps ORDER BY id DESC LIMIT 20"`.
   Map each row to a box in the PHASE-A-2 state diagram.
2. **Watch a compensation.** Set a SKU's stock to 1 (admin UI or `PATCH /api/v1/inventory/{sku}`), check out
   quantity 2, and find the `InventoryReservationFailed` → `CANCELLING` → `CANCELLED` steps.
3. **Prove dedupe.** In the saga tests, find "a redelivered event (same messageId)…" and explain which line of
   `repository.ts` makes it a no-op.
4. **Find the stall.** Without running anything, explain to yourself (or write it down) exactly which line of the
   saga `outbox-relay.ts` causes P1-2, and design the test from the risks file.
5. **Workflow reading.** For `ecommerce-auth-service`, list in order every step that runs on a push to `main` once
   `phase7` is merged, including the called workflows.

### Acceptance criteria for Phase A

- You can draw the system diagram and the dependency map from memory, marking sync vs async edges.
- You can name each service's DB engine, migration tool and the command CI uses to test its migrations.
- You can walk the happy path and at least 8 failure rows of the saga table, naming the compensating action and
  the idempotency key involved.
- You can explain P1-1, P1-2 and P1-4 to someone else, with the file and line.
- You can answer the four "unresolved questions" at the end of PHASE-A-5, or know who to ask.

When you are ready, say **"ready for Phase B"**, or jump straight to Phase J (CI/CD) if that's your priority.
