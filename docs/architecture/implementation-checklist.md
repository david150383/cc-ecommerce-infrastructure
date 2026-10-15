# Implementation Checklist

Tick items only when they have been implemented **and verified**.

## Phase 1: Architecture and project setup
- [x] Architecture, dependency map, database ownership, saga sequence documented
- [x] Platform conventions (IDs, money, time, errors, envelope, JWT) documented
- [x] Messaging topology documented and expressed in Terraform (validated, not applied)
- [x] Nine repositories created (contracts deferred to Phase 6), each with its own git history
- [x] Each repo: README, .env.example, Dockerfile, CI workflow, health endpoints, passing tests
- [x] Each service: `docs/api.md` + `docs/events.md` + JSON Schemas with validated examples
- [x] Local compose environment (Postgres per-service roles, Mongo, Floci, Mailpit)
- [x] All 8 images build; full stack runs healthy in compose; containers run as non-root
- [x] Database isolation verified (cross-service connections refused)
- [x] Messaging topology applied to the local emulator; filter-policy routing verified (`scripts/verify-local-messaging.sh`)
- [ ] GitHub remotes created (`scripts/create-github-repos.sh`, needs `gh`)
- [ ] CI workflows observed passing on GitHub (needs remotes)

## Phase 2: Foundational services
- [x] Auth: Prisma schema + migrations, register/login/refresh/logout, JWKS, Argon2id, rate limits, audit log
- [x] Auth: email verification, password reset, admin users, OpenAPI
- [x] Auth: client-credentials service tokens (per-target audience)
- [x] Product: SQLAlchemy models, Alembic migrations, CRUD, categories, search/filter/paginate
- [x] Inventory: TypeORM entities + migrations, stock CRUD, reservations with row locks, idempotency, audit
- [x] Inventory: concurrent-reservation test proving no oversell
- [x] Order: Mongoose models, price snapshot via Product, state machine, ownership checks
- [x] Shared-nothing JWT verification via JWKS in Product, Inventory, Order
- [x] Migrations as one-off `migrate` jobs before each service starts
- [x] Hand-driven checkout across Auth, Product, Inventory, Order containers
- [ ] CI observed green on GitHub (needs remotes)

## Phase 3: Messaging and saga
- [x] Apply messaging module to the local emulator (Floci since Phase 3)
- [x] Floci replaces LocalStack (persistent hybrid storage); `messaging-init` job in compose
- [x] Outbox relay in Auth, Inventory, Order; idempotent command consumers in Inventory and Order
- [x] Services verified end to end over the real queues (`scripts/verify-service-messaging.py`)
- [x] order-commands is a FIFO queue (per-order ordering of status transitions)
- [x] Saga Orchestrator: pure state machine, persistence, outbox, inbox dedupe, timeouts, compensation, recovery, manual review
- [x] Tests: happy path, out of stock, payment failure/timeout, duplicate messages, concurrency, crash/restart (unit, integration, Floci)
- [x] Checkout end to end through the real services incl. a SIGKILLed saga (`scripts/verify-checkout-saga.py`)

## Phase 4: Payment and notifications
- [x] Payment: mock provider (hosted test page) + Stripe test-mode adapter, signed webhooks, refunds, reconciliation
- [x] Checkout end to end through the real Payment Service: pay, decline, admin refund, late payment refunded, forged webhook (`scripts/verify-checkout-saga.py`)
- [x] Notification: templates, preferences, email (SMTP/Mailpit), SMS adapter, retries with backoff, DLQ monitor
- [x] Auth's secret-bearing email through the Notification Service; notifications end to end (`scripts/verify-notifications.py`)
- [x] Tests: duplicate webhooks, failed payment, refund (Payment Service)
- [x] Tests: notification retry, secret never stored or logged

## Phase 5: Frontend
- [x] Auth flows, catalog, cart, checkout, payment result, order tracking
- [x] Customer account pages, admin pages
- [x] Full platform running in compose; end-to-end smoke test (`ecommerce-frontend`: `npm run e2e`, Playwright)
- [ ] Known gap: customer cancellation of a PAID order stops at CANCELLATION_PENDING (no refund/close flow); the UI does not offer it

## Phase 6: ecommerce-contracts
- [x] Extract OpenAPI, JSON Schema, AsyncAPI; ownership matrix; versioning policy
- [x] CI compatibility checks; tagged release (v1.0.0, v1.1.0); pinned consumers; breaking-change demo
- [ ] Known gap: Inventory publishes no OpenAPI response schemas, so its responses are not contract-checked

## Phase 7: Production readiness
- [x] ECS deployment design (network, platform, data, service, frontend, WAF, stack; dev/staging/prod), planned offline against a mocked provider with `terraform test`. **Not applied** (needs approval and the one-time setup in deployment.md)
- [x] GitHub OIDC deploy roles (per repository and GitHub environment), Secrets Manager (per service, values out of band), alarms (ALB, services, databases, DLQs)
- [x] Deploy pipelines (generated into every repository, actionlint-clean); nightly E2E workflow with contract-pin verification
- [x] Security review (security-review.md): scans with evidence, 12 findings (S-1 inventory hoarding and S-2 per-task rate limits fixed)
- [x] Recovery and rollback drills run locally with real output (runbooks.md): PostgreSQL and MongoDB restore, DLQ redrive, rollback; saga crash recovery (Phases 3–4)
- [ ] Open: first apply in a dev account (approval); measure real RTO/rollback times in staging; S-8, S-9, S-11, S-12 (security-review.md)
