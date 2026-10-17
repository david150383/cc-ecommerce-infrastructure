# Phase M-4: Production Readiness: Scorecard, Shutdown, Go-Live Checklist, Findings

## 1. Readiness scorecard

✓ = in place (code/config read); ◐ = partial or designed but unverified; ✗ = missing. "Evidence" points to code or to
earlier phases.

| Area | Item | Status | Evidence / note |
|---|---|---|---|
| **Correctness** | Idempotency end to end (HTTP keys, command keys, provider keys) | ✓ | A-2, Phase E/G areas |
| | No-oversell, bounded refunds, money truth wins | ✓ | A-2 |
| | Saga recovery after crash (deadlines, leases, startup drain) | ✓ | A-2, drills |
| | Outbox failure isolation | ✗ | P1-2 |
| **Reliability** | Rolling deploys with circuit-breaker rollback | ◐ | designed (K-2); never run |
| | Graceful shutdown | ◐ | §2 below (M-F5) |
| | Multi-AZ data (prod) | ◐ | RDS Multi-AZ, DocumentDB replica (designed) |
| | Backups and restore procedure | ◐ | drills locally; RTO/RPO not measured on real sizes |
| | DB connection budget | ✗ | K-F6 |
| **Observability** | Structured logs with redaction | ✓ | M-2 §1 |
| | Correlation across hops | ◐ | messages yes, HTTP no (M-F3) |
| | Health: liveness vs readiness | ✓ | M-2 §3 |
| | Infra alarms defined | ◐ | defined, **undeliverable** (P1-1) |
| | Business alarms (manual review, outbox lag) | ✗ | M-F1, M-F2 |
| | Metrics, dashboards, tracing | ✗ | M-F4 |
| **Security** | Edge: WAF, TLS, CSP, private origins | ◐ | WAF bypassable (K-F1) |
| | Least-privilege IAM, OIDC deploys, no static keys | ✓/◐ | K-3; DLQ gap (K-F2); IAM untested (K-F10) |
| | Secrets out of code/state | ✓ | K-3 |
| | Dependency/image scanning, action pinning | ◐ | audits yes; image scan and SHA pins no (J-F7, J-F9) |
| **Delivery** | CI on every PR | ✓ | J-1/J-2 (live on GitHub `main` today) |
| | Build once, promote; idempotent publish | ✗ | J-F1, J-F3 |
| | Post-deploy smoke before promotion | ✗ | M-1 §2 |
| | Approval gate for prod | ◐ | depends on GitHub Environment settings (not visible) |
| **Contracts** | Message compat + pinning | ✓ | Phase L |
| | HTTP breaking-change gate in producers | ✗ | L-F1 |
| **Operations** | Runbooks (rollback, restore, DLQ, stuck saga, rotation) | ✓ | runbooks.md |
| | On-call: who gets paged, escalation | ✗ | no alert routing beyond email subscriptions |
| | Account guardrails (CloudTrail, GuardDuty, Config) | ✗ | K-F13 (outside this repo) |
| **Performance** | Load test / capacity baseline | ✗ | M-1 §2 |

## 2. Graceful shutdown: line by line (saga as the example)

[server.ts:72-100](ecommerce-saga-orchestrator/src/server.ts#L72-L100):
1. `SIGTERM` → `shuttingDown = true` → `/health/ready` returns 503 from now on.
2. **Immediately** `server.close()` (no new connections) + `closeIdleConnections()`.
3. When in-flight HTTP finishes: `workers.stop()` (abort the long poll, let the relay/timer finish their tick), then `db.end()`, then exit 0.
4. A safety net: `SHUTDOWN_TIMEOUT_MS` (10 s) → `process.exit(1)`.

The other Node services follow the same pattern. Inventory (Nest) flips readiness in `beforeApplicationShutdown`; Product
relies on Uvicorn's SIGTERM drain.

**What happens on ECS (M-F5, PLAUSIBLE: depends on timing, so verify in staging):** when ECS stops a task during a rolling
deploy, it starts deregistering it from the ALB target group **and** sends SIGTERM at roughly the same time.
Deregistration propagates over a few seconds (the delay is 30 s here). Steps 1–2 above make the readiness check irrelevant
(the ALB doesn't consult it once deregistering), and the closed listener refuses connections the ALB still sends, which
shows up as **502s during every deploy**. Also, long requests are cut at 10 s, while the ALB allows 30 s of draining.

Usual pattern:
- On SIGTERM, keep serving for ~5–10 s (readiness 503, listener open) so the deregistration propagates, **then** close.
- `SHUTDOWN_TIMEOUT_MS` < ECS `stopTimeout` (30 s), and both > the expected request time.

Verify: during a staging deploy, watch `HTTPCode_ELB_502_Count` and `HTTPCode_Target_5XX_Count` under a constant synthetic load.

Messaging side: in-flight SQS messages that a stopping consumer hadn't deleted reappear after the visibility timeout
(60 s) and are reprocessed idempotently. That costs latency but loses nothing.

## 3. Go-live checklist (ordered; nothing here is urgent while `phase7` stays unmerged)

**Before the first AWS apply**
- [ ] K-F1 edge bypass fixed (VPC origin or a secret header)
- [ ] P1-1 alarm topic encryption fixed; one alarm drill delivered by email
- [ ] K-F2 notification DLQ IAM; K-F10 messaging policy tests
- [ ] K-F5 account / OIDC-provider layout decided; K-F7 Terraform version constraint
- [ ] P1-4/J-F4 task-definition ownership; J-F1/J-F3 build once + idempotent publish
- [ ] J-F5 repo prefix variable (`cc-ecommerce-`); contracts repo pushed

**Before the first customer**
- [ ] P1-2 outbox poison isolation (+ test); M-F2 outbox-lag metric and alarm
- [ ] M-F1 manual-review alert
- [ ] M-F5 shutdown sequence; post-deploy smoke gating promotion
- [ ] K-F6 pool sizes; load test in staging (checkout funnel, WAF thresholds vs CGNAT)
- [ ] L-F1 HTTP breaking-change gate; L-F3 parse backend responses
- [ ] Real RTO/RPO measured: PITR restore of staging; rollback timing
- [ ] Nightly E2E green for 7 consecutive nights (J-F12 fixed)
- [ ] GitHub Environments + branch protection configured; deploy actions pinned by SHA
- [ ] Stripe live mode: webhook endpoint registered, secret stored, a test refund in live mode with a real card (small amount)
- [ ] SES out of sandbox; SPF/DKIM/DMARC for the sending domain

**After launch (first weeks)**
- [ ] Dashboards per M-2 §5; review alarm noise weekly
- [ ] Game day: kill a service, block SQS, expire a reservation mid-payment. Confirm the runbooks hold.

## 4. Phase M findings

| ID | Priority | Finding | Status | Evidence | Fix | Effort |
|---|---|---|---|---|---|---|
| **M-F1** | **P1** | `MANUAL_REVIEW` (money possibly taken, goods/order inconsistent) raises **no alert**: `SagaManualReviewRequired` goes to `saga-events`, which has no subscriptions; only the admin dashboard shows it | CONFIRMED | [messaging/main.tf](ecommerce-infrastructure/terraform/modules/messaging/main.tf) subscriptions (none for saga-events); [AdminLayout.tsx:80-95](ecommerce-frontend/src/pages/admin/AdminLayout.tsx#L80-L95); checkout-saga.md says "and alert" | Subscribe an alert target with a filter on that type, or a metric + alarm | low |
| **M-F2** | **P1** | No outbox-lag signal: a stalled relay produces **no** queue alarms (nothing enters the queues) | CONFIRMED | no metric/filter in Terraform; relays only log | Emit oldest-unpublished-age per relay tick (EMF) + an alarm | low |
| M-F3 | P2 | Correlation id isn't forwarded on service-to-service HTTP; the saga uses `saga.id` as the message correlation id | CONFIRMED | grep: `x-correlation-id` only in inbound middleware; [engine.ts:136](ecommerce-saga-orchestrator/src/saga/engine.ts#L136) | Forward the header in clients; store the request's correlation id on the saga | low |
| M-F4 | P2 | No application metrics, dashboards or tracing | CONFIRMED | no metrics/OTel code or Terraform dashboards | EMF business metrics → dashboards → OTel + ADOT | medium |
| M-F5 | P2 | Shutdown closes the listener at SIGTERM; 10 s forced exit vs 30 s ALB drain, so likely 502s during deploys | PLAUSIBLE | [server.ts:72-97](ecommerce-saga-orchestrator/src/server.ts#L72-L97) (same pattern in all Node services) | Pre-stop delay with readiness 503, then close; align timeouts | low |
| M-F6 | P2 | Cross-service verification and the browser E2E run only by hand; the nightly can't run | CONFIRMED | J-F5, J-F12 | Fix e2e.yml; run before merging `phase7` | low |
| M-F7 | P2 | No post-deploy smoke test gates promotion dev → staging → prod | CONFIRMED | deploy-environment.yml ends at rollout COMPLETED | Smoke job per environment | low |
| M-F8 | P3 | Product's log redaction is top-level only; inventory's redact list is shorter than the other Node services' | CONFIRMED | logging.py, logger.options.ts | Align redaction lists; recursive redaction in structlog | low |
| M-F9 | P3 | Untested scenarios: outbox poison row, pay-and-cancel race, migration compatibility (old code + new schema), system load | CONFIRMED | M-1 §2 | Tests as designed in M-1 §3 | medium |

## 5. Hands-on exercises (read or run locally only if you choose; no repo changes)

1. **Trace one checkout by ids:** pick a `sagaId` from a local checkout and write the exact Logs Insights / `docker compose logs | grep`
   sequence to find every log line in saga, order, inventory, payment and notification. Note where you had to switch from
   `correlationId` to `orderId`.
2. **Design the outbox-lag metric:** write (outside the repos) the EMF JSON line the saga relay would emit per tick, and
   the CloudWatch alarm (namespace, metric, threshold, period).
3. **Shutdown timeline:** draw a 0–40 s timeline of a rolling deploy for one task: SIGTERM, deregistration, `server.close`,
   the forced exit, the ALB drain. Mark where 502s can occur, then redraw it with a 10 s pre-stop delay.
4. **Runbook dry-run:** using only M-3 and runbooks.md, write the exact steps you'd take if 30 sagas were stuck in
   `RESERVING_INVENTORY` and the inventory-commands queue had 0 messages. (Hint: where would the commands be?)
5. **Readiness review:** pick three ✗ rows in the scorecard and write the smallest change that turns each into ◐.

## 6. Interview-style questions

- *Liveness vs readiness: what goes wrong if liveness checks the database?* A DB blip fails liveness everywhere, ECS
  restarts every task, and you get a self-inflicted outage plus a thundering herd on recovery.
- *Why doesn't "all queues healthy" mean "messages are flowing"?* Producers publish from outboxes. If a relay stalls,
  queues look empty and healthy. You need producer-side lag.
- *How do you follow one business transaction across HTTP and queues?* Propagate one correlation id through headers and
  envelopes (plus causation ids for the chain), and log business ids. Ideally use trace context (W3C `traceparent`) in both.
- *What does a drill prove that a test doesn't?* That the **procedure and the people/tools** work: commands, permissions,
  timing, and that the system recovers (e.g. messages processed exactly once after a rollback).

## 7. Phase M summary

**Topics covered:** the test pyramid as implemented; cross-service scripts and drills; gaps and designs for hard tests;
logging, redaction, correlation, health, metrics, alarms, tracing; a symptom-driven playbook; graceful shutdown;
a readiness scorecard and go-live checklist.

**Files examined:** `runbooks.md`, `local-development.md` (troubleshooting), the `verify-*.py` scripts and
`drills/rollback.sh`, `e2e/smoke.spec.ts`, saga `logger.ts`, `request-context.ts`, `health.ts`, `server.ts`, product
`logging.py` + `middleware.py`, inventory `logger.options.ts` + `readiness.service.ts`, saga `order-client.ts`, saga/notification/payment
migrations (columns for queries), admin UI (`AdminLayout.tsx`, `AdminOperations.tsx`), messaging subscriptions; greps for
metrics/tracing libraries and `x-correlation-id`.

**Commands executed (read-only):** `cat`, `sed`, `grep`. Nothing run against the stack.

**Unresolved questions:** Who should receive production alerts (email only, or Slack/PagerDuty via AWS Chatbot)? Do you
want OpenTelemetry tracing, or is EMF metrics + logs enough for this project's scale?

## 8. Acceptance criteria for Phase M

- You can name each test layer, where it runs, what it mocks, and what it can't catch.
- You can design tests for concurrency, duplicate delivery, webhook retries, saga crash recovery and migration compatibility.
- You can diagnose a stuck checkout from its saga state using the queries in M-3.
- You can explain why M-F1 and M-F2 are the two highest-value observability fixes.
- You can explain the shutdown timeline and why it may produce 502s.

Next: **Phase N**, the consolidated, de-duplicated backlog across all phases (A, J, K, L, M), or Phase B to go back in order.
