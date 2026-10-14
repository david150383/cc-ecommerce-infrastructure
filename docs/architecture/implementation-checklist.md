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
- [ ] Extract OpenAPI, JSON Schema, AsyncAPI; ownership matrix; versioning policy
- [ ] CI compatibility checks; tagged release; pinned consumers; breaking-change demo

## Phase 7: Production readiness
- [ ] ECS deployment module, OIDC roles, Secrets Manager, alarms
- [ ] Security review, recovery/rollback drills, E2E + contract tests in CI
