# Phase N: Consolidated, Prioritized Improvement Backlog

This is the single backlog for the platform. Every finding from Phases A, J, K, L and M is merged here, without
duplicates, under one **N-ID**. The original IDs are kept in brackets so you can trace each item back to its detailed
analysis. The ground rules are unchanged: this is a plan, nothing was changed, run or deployed, and `phase7` stays unmerged.

## How to read this

**Priorities**
- **P0**: critical security, financial-correctness or data-loss risk in a running system.
- **P1**: major reliability, correctness or deployment risk.
- **P2**: maintainability, coverage, performance, operations.
- **P3**: optional enhancements.

**Status** (how confident each finding is)
- **CONFIRMED**: certain from code or config.
- **CONFIRMED + AWS docs**: config certain; consequence per documented AWS behavior.
- **PLAUSIBLE**: needs a run to confirm.

**Mandatory vs optional.** "Mandatory" items must be done **before the stated gate**. Everything else is a judgment call,
and §5 lists items that are explicitly optional preferences.

### Why there is no P0

There are no P0 items. The money and stock paths are well protected:
- idempotency end to end;
- signed and deduplicated webhooks;
- refunds bounded and keyed;
- overselling prevented in one SQL statement;
- recovery after a saga crash.

Nothing runs in AWS yet, so no risk is live. Several P1 items **become P0 at go-live** (alerting, edge bypass,
deploy/rollback correctness). That's why they are marked mandatory.

## 1. Summary table

| N-ID | Pri | Title | Gate (mandatory before…) | Repos | Effort |
|---|---|---|---|---|---|
| N-01 | P1 | Alarms can't be delivered (alarm topic uses the AWS-managed SNS key) | first AWS apply | infrastructure | low |
| N-02 | P1 | Outbox: one poison row stalls all saga messages; no outbox-lag signal | first customer (code: now) | saga (+ all relays), infrastructure | medium |
| N-03 | P1 | Manual-review sagas raise no alert | first customer | infrastructure (+ saga optional) | low |
| N-04 | P1 | WAF/CloudFront can be bypassed via any CloudFront distribution | first AWS apply | infrastructure | low–medium |
| N-05 | P1 | Notification can't read its DLQs in AWS; IAM policies untested | first AWS apply | infrastructure | low |
| N-06 | P1 | Task-definition ownership split: Terraform env/secret changes never deploy | first AWS apply | infrastructure, 8 deploy workflows | medium |
| N-07 | P1 | Deploy rebuilds per environment; reruns/rollbacks fail on immutable tags; 10-min migration waiter | first AWS apply | infrastructure templates → 8 repos | medium |
| N-08 | P1 | Repo prefix `cc-` not parameterized; contracts repo has no remote; nightly E2E can't run | merging `phase7` | infrastructure, contracts | low |
| N-09 | P1 | CI on `main` can cancel the deploy's CI; deploy fires with no AWS; GitHub Environments/branch rules | merging `phase7` | 8 repos (generator), GitHub settings | low |
| N-10 | P1 | HTTP breaking changes aren't gated in the producer; backend clients cast instead of parse | first customer | all services, contracts | medium |
| N-11 | P1 | `messageVersion` not routable or dispatched | the **first v2 message** | infrastructure, all relays and consumers, contracts | medium |
| N-12 | P1 | DB connection budget exceeds small instances; fixed 300 alarm | first AWS apply (dev) | services (env), infrastructure | low |
| N-13 | P1 | Shutdown → likely 502s during deploys; no post-deploy smoke before promotion | first customer | all services, deploy templates | low |
| N-14 | P2 | Single AWS account; dev owns the account-wide OIDC provider | decision before first apply | infrastructure | medium |
| N-15 | P2 | Captured amount ≠ order total is only logged | first customer | payment, saga | low |
| N-16 | P2 | Pay-and-cancel race ends in MANUAL_REVIEW, untested | — | saga (+ order) | medium |
| N-17 | P2 | Orphan PENDING order after `FAILED`; provider session not expired on timeout | — | saga, order, payment | low |
| N-18 | P2 | Coarse network isolation (one tasks SG, open egress, plain HTTP inside the VPC, one RDS for 6 DBs) | — | infrastructure | medium |
| N-19 | P2 | Supply chain: tag-pinned actions/base images, no secret scan, no image scan/SBOM, no update bot | — (deploy actions: first apply) | all 10 | low |
| N-20 | P2 | Contract process: command deploy-order rule; OpenAPI provenance; branch pins | — | contracts | low |
| N-21 | P2 | Observability: correlation not forwarded; no app metrics, dashboards, tracing | first customer (minimal set) | all services, infrastructure | medium–high |
| N-22 | P2 | DB roles: manual bootstrap, no rotation, `sslmode=require` | first AWS apply (codify) | infrastructure, services | medium |
| N-23 | P2 | Autoscaling CPU-only for queue consumers | — | infrastructure | low |
| N-24 | P2 | Order Service never tested on real DocumentDB | first customer | order | medium |
| N-25 | P2 | Documentation drift (saga states, tables, checklist, deployment vars, envelope text, visibility claim) | — | infrastructure docs, contracts | low |
| N-26 | P2 | Generated deploy workflows can drift (no `--check`); consider central reusable workflows | — | infrastructure | low–medium |
| N-27 | P2 | Missing tests: pay/cancel race, migration compatibility, load, full `down` migrations, response conformance | — | several | medium |
| N-28 | P2 | `POST /api/v1/payments/intent` (service-only) is publicly routable | — | payment, saga, infrastructure | low |
| N-33 | P2 | Admin UI tells operators to refund `CANCELLATION_PENDING` orders by hand (stale since the automated flow), so admin and saga refunds race → manual review | first customer | frontend (+ docs) | low |
| N-29 | P3 | `compat` ignores errors/security; no deprecation signals | — | contracts, services | medium |
| N-30 | P3 | Edge and infra logging (ALB, CloudFront, WAF, flow logs); account guardrails | before first customer (guardrails) | infrastructure, AWS org | medium |
| N-31 | P3 | Hygiene bundle (Terraform constraint, lock files, redaction alignment, small K/J items) | — | various | low |
| N-32 | P3 | Accepted trade-offs to document (token TTL, duplicate emails, refresh grace) | — | auth, notification, docs | low |

---

## 2. P1 items (detail)

### N-01 Alarm delivery is broken  [P1-1, K-F3]
- **Problem:** the `alarms` SNS topic is encrypted with `alias/aws/sns`. CloudWatch alarm actions can't publish to topics
  encrypted with the AWS-managed key, so **every** alarm (DLQ, queue age, 5xx, tasks, DB) would reach nobody.
- **Evidence:** [platform/main.tf:207-211](ecommerce-infrastructure/terraform/modules/platform/main.tf#L207-L211); all alarm modules use this topic. CONFIRMED + AWS docs.
- **Why it matters:** every other operational safeguard (DLQ alarms, manual review, outbox lag) depends on alarm delivery.
- **Solution:** a customer-managed KMS key whose policy grants `cloudwatch.amazonaws.com` (and SNS) `kms:Decrypt` +
  `kms:GenerateDataKey*`, or no encryption on this topic (it carries no customer data). Add a `terraform test` assertion.
- **Effort:** low. **Risk of change:** a wrong key policy blocks publishing too, so drill it.
- **Verify:** dev apply, then `aws cloudwatch set-alarm-state --state-value ALARM …`, then the email arrives.

### N-02 Outbox poison row + no outbox-lag signal  [P1-2, M-F2, P2-6, part of M-F9]
- **Problem:** the saga relay stops at the first failed send, and the failing row is always the oldest. One permanently
  failing row (bad queue name, IAM deny, >256 KB) blocks **every** saga's messages. Queues then look healthy (empty), so
  no queue alarm fires.
- **Evidence:** [saga outbox-relay.ts:79-83](ecommerce-saga-orchestrator/src/messaging/outbox-relay.ts#L79-L83); no lag metric anywhere. CONFIRMED.
- **Why it matters:** total checkout stall with no signal. Compensations queue behind the same row.
- **Solution:**
  - (a) Isolate failures per saga while keeping per-saga order: record `last_error` and `next_attempt_at`, skip sagas whose
    head row is failing, and `continue` with the others. After N attempts mark the row `failed` and log at error level.
  - (b) Each relay tick emits `oldestUnpublishedAgeSeconds` (CloudWatch EMF log line), with an alarm when it exceeds 60 s.
  - (c) Optional: claim rows in a short transaction and send outside it (P2-6).
  - Apply (b) to the auth, inventory, payment and order relays too.
- **Repos:** saga (and the other relays for the metric), infrastructure (alarm). **Effort:** medium.
- **Risk of change:** breaking the per-saga ordering the FIFO order queue depends on. Keep the existing "two relays racing" test.
- **Verify:** a new integration test with one row to a nonexistent queue plus a valid row of another saga. The valid row
  must publish, and the metric must report the stuck row's age.

### N-03 Manual review alerts nobody  [M-F1]
- **Problem:** `SagaManualReviewRequired` goes to `saga-events`, which has no subscribers. Operators see it only on the admin dashboard.
- **Evidence:** [messaging/main.tf](ecommerce-infrastructure/terraform/modules/messaging/main.tf) subscriptions; [AdminLayout.tsx:80-95](ecommerce-frontend/src/pages/admin/AdminLayout.tsx#L80-L95). CONFIRMED.
- **Why it matters:** these are the cases where money may have been taken and the order is inconsistent.
- **Solution:** a subscription on `saga-events` filtered to that type, delivering to an ops queue/email/Chatbot. Or a
  metric "sagas in MANUAL_REVIEW" with an alarm when it's > 0. Requires N-01.
- **Effort:** low. **Verify:** drive a saga to MANUAL_REVIEW locally (refund failure path) and see the alert (in AWS, after N-01).

### N-04 Edge bypass of the WAF  [K-F1]
- **Problem:** the ALB admits CloudFront's global origin-facing prefix list, and its rules match only the path. Anyone's
  CloudFront distribution can reach the API without passing your WAF.
- **Evidence:** [platform/main.tf:74-91](ecommerce-infrastructure/terraform/modules/platform/main.tf#L74-L91); the `api`
  origin in [frontend/main.tf](ecommerce-infrastructure/terraform/modules/frontend/main.tf) has no custom header. CONFIRMED + AWS behavior.
- **Why it matters:** brute-force protection on auth (WAF 100/5 min/IP) and the managed rules are bypassed.
  Security-review S-3 is marked fixed but is incomplete.
- **Solution:** either
  - CloudFront **VPC origins** with an internal ALB (preferred: no public ALB), or
  - a secret `X-Origin-Verify` header that every ALB rule requires (stored in Secrets Manager, rotated). Add tests.
- **Effort:** low–medium. **Risk of change:** a header mismatch returns 403 for the whole API, so roll out in dev first.
- **Verify:** a direct request to `origin-api.<domain>` returns 403; through the shop domain returns 200.
- **Your decision:** VPC origin or secret header.

### N-05 DLQ permissions + IAM tests  [K-F2, K-F10]
- **Problem:** Notification's DLQ monitor and the admin dead-letters page call `GetQueueUrl/GetQueueAttributes/ReceiveMessage/ChangeMessageVisibility`
  on DLQs, but IAM grants these only on the main queues. Floci doesn't enforce IAM, and the messaging module has no tests.
- **Evidence:** [dlq-monitor.ts:29-60](ecommerce-notification-service/src/messaging/dlq-monitor.ts#L29-L60), [messaging/main.tf:65](ecommerce-infrastructure/terraform/modules/messaging/main.tf#L65), [service.tftest.hcl:14-16](ecommerce-infrastructure/terraform/modules/service/tests/service.tftest.hcl#L14-L16). CONFIRMED.
- **Solution:** add a `inspect_dlqs` list to `service_access`. Add `modules/messaging/tests/` asserting the policy JSON per
  service (saga sends to exactly 4 queues; notification may read its 2 DLQs; nobody else may).
- **Effort:** low. **Verify:** `terraform test`; after the dev apply, `aws iam simulate-principal-policy` against the DLQ ARN.

### N-06 One owner for task definitions  [P1-4, J-F4, K-F4]
- **Problem:** Terraform ignores `container_definitions`; CI copies the live definition and swaps only the image. Env and
  secret changes made in Terraform never reach ECS.
- **Evidence:** [service/main.tf:289-292](ecommerce-infrastructure/terraform/modules/service/main.tf#L289-L292), [deploy-environment.yml:74-77](ecommerce-auth-service/.github/workflows/deploy-environment.yml#L74-L77). CONFIRMED.
- **Solution (pick one):**
  - (a) Terraform owns the task definition, and CI passes `image_tag` (requires a Terraform CD step with plan + approval).
  - (b) CI owns it from a committed template in each repo.
  - (c) CI reads env/secret config from SSM parameters that Terraform writes.
- **Repos:** infrastructure (+ templates → 8 repos). **Effort:** medium.
- **Risk of change:** the first deploy after switching can reset config. Diff old vs new revisions.
- **Verify:** change one env var, apply + deploy, then `describe-task-definition` shows it.

### N-07 Build once, idempotent publish, working reruns and rollbacks  [P1-5, J-F3, J-F1, J-F11]
- **Problem:**
  - Each environment rebuilds its image, so production never runs the bytes staging tested.
  - With IMMUTABLE ECR tags, re-running a deploy, or re-running a commit "to roll back" (as the runbook suggests), fails at `--push`.
  - The migration waiter caps at about 10 minutes.
- **Evidence:** [deploy-environment.yml:45-69](ecommerce-auth-service/.github/workflows/deploy-environment.yml#L45-L69), [platform/main.tf:183](ecommerce-infrastructure/terraform/modules/platform/main.tf#L183), runbooks.md §Rollback. CONFIRMED.
- **Solution:**
  - One build job: arm64 (native runner or QEMU) for `runtime` + `migrate`, pushed to one registry (or replicated),
    with provenance/SBOM, outputting the **digest**.
  - Environment jobs deploy `repo@sha256:…`.
  - "Skip if tag exists" for reruns; your own polling loop for migrations.
  - Update the runbook: roll back with `update-service --task-definition <previous revision>`.
- **Repos:** infrastructure templates + regenerate into 8 repos. **Effort:** medium.
- **Verify:** deploy the same commit twice (the second is a no-op success); a rollback via the previous revision works.

### N-08 Make the cross-repo pieces runnable  [P1-3, J-F5, J-F12, L-F6, M-F6]
- **Problem:**
  - OIDC trust and `e2e.yml` hard-code `ecommerce-*`, but your repos are `cc-ecommerce-*` (intentional).
  - Contracts has no remote.
  - The nightly can't clone private repos.
  - The most valuable tests (verify-*.py, Playwright) therefore run only by hand.
- **Evidence:** [stack/main.tf:313](ecommerce-infrastructure/terraform/modules/stack/main.tf#L313), [e2e.yml:25](ecommerce-infrastructure/.github/workflows/e2e.yml#L25), `git remote -v`. CONFIRMED.
- **Solution:**
  - A `repo_prefix` variable (default `cc-ecommerce-`) and a `REPO_PREFIX` env.
  - Clone into `ecommerce-*` directories with `actions/checkout` + a read token.
  - Push `cc-ecommerce-contracts`.
  - Make `verify-contracts` assert that the pinned `version` is a tag.
- **Effort:** low. **Verify:** a manual `workflow_dispatch` of `e2e.yml` goes green.

### N-09 CI/deploy workflow safety  [P1-6/J-F2, P2-1/J-F6, J-F14, part of J-5]
- **Problem:**
  - On `main`, the push-triggered CI and the CI called by `deploy.yml` share the `ci-refs/heads/main` concurrency group and can cancel each other.
  - `deploy.yml` fires on every push while AWS doesn't exist.
  - `deploy.yml` has no top-level permissions block.
  - Environment and branch rules aren't visible or confirmed.
- **Evidence:** [ci.yml:12-14](ecommerce-auth-service/.github/workflows/ci.yml#L12-L14), [deploy.yml:8-11](ecommerce-auth-service/.github/workflows/deploy.yml#L8-L11). CONFIRMED (collision PLAUSIBLE).
- **Solution:**
  - `group: ${{ github.workflow }}-${{ github.ref }}`.
  - `workflow_dispatch` only (or an `if: vars.AWS_DEPLOY_ROLE_ARN != ''` guard) until infra exists.
  - Top-level `permissions: contents: read`.
  - On GitHub: Environments with `main`-only deployment branches, production reviewers, and branch protection with required checks.
- **Effort:** low (edit the template + regenerate). **Verify:** a push to a test branch → only CI runs; a dispatch on a non-main branch → the environment refuses it.

### N-10 HTTP compatibility gate in producers + parse in clients  [L-F1, L-F3]
- **Problem:** a service can break its own HTTP API and pass its CI, because the drift test only checks that the file matches the code. Backend clients use
  casts, so a rename fails as a `TypeError` that the saga treats as "dependency failed" (every checkout ends `FAILED`).
- **Evidence:** `openapi.test.ts` in each service; [order-client.ts:79-80](ecommerce-saga-orchestrator/src/clients/order-client.ts#L79-L80). CONFIRMED.
- **Solution:**
  - (a) Each service's CI compares its generated OpenAPI against the last **published** one and fails on breaking changes
    without `/api/v2`, using the vendored `compat` lib or `oasdiff breaking`.
  - (b) Clients parse responses with Zod (fail loudly, with context).
  - (c) Later: backends vendor callee OpenAPI and test against it.
- **Repos:** 7 services, contracts. **Effort:** medium. **Depends on:** N-08 (published contracts remote).
- **Verify:** on a scratch branch, rename an Order response field and confirm Order's CI fails.
- **Your decision:** own `compat` lib vs `oasdiff`.

### N-11 `messageVersion` routing and dispatch  [L-F2]
- **Problem:** the documented breaking-change path for events ("emit v1 and v2") would deliver v2 to v1 consumers, because
  SNS attributes and filter policies carry only `messageType`, and no consumer reads `messageVersion`.
- **Evidence:** relays' `MessageAttributes` ([saga outbox-relay.ts:97](ecommerce-saga-orchestrator/src/messaging/outbox-relay.ts#L97)); `filter_policy` in messaging/main.tf. CONFIRMED.
- **Solution:**
  - Publish `messageVersion` as an attribute, and filter on `{messageType, messageVersion}`.
  - Consumers dispatch on both and ack+log unknown versions.
  - Document the bindings in AsyncAPI.
- **Gate:** mandatory only **before the first v2** of any message. **Effort:** medium.

### N-12 Database connection budget  [K-F6]
- **Problem:** about 60 connections with one task per service; about 120 during a full rolling deploy. Dev's `db.t4g.micro`
  allows roughly 80–110. Prod at max scale is about 600. The alarm threshold is fixed at 300.
- **Evidence:** pool defaults (`createPool(url, max = 10)` etc.), [data/main.tf:202](ecommerce-infrastructure/terraform/modules/data/main.tf#L202). PLAUSIBLE (exact limits vary).
- **Solution:** explicit `DB_POOL_SIZE` per service via the stack env (e.g. 3–5), per-class alarm thresholds, and RDS Proxy for prod.
- **Effort:** low. **Verify:** `SELECT count(*) FROM pg_stat_activity` during a full deploy in dev.

### N-13 Deploy-time correctness: shutdown and smoke  [M-F5, M-F7]
- **Problem:**
  - Services close their listener immediately on SIGTERM and force-exit at 10 s, while the ALB drains for up to 30 s. That's likely 502s on every deploy.
  - Promotion dev → staging → prod has no functional smoke test.
- **Evidence:** [saga server.ts:72-97](ecommerce-saga-orchestrator/src/server.ts#L72-L97) (same pattern in the other Node services); deploy-environment.yml. PLAUSIBLE / CONFIRMED.
- **Solution:**
  - Pre-stop delay: readiness returns 503 and the listener stays open for ~5–10 s, then close; align `SHUTDOWN_TIMEOUT_MS` < `stopTimeout`.
  - A smoke job per environment (catalog GET + synthetic login via the shop origin) that gates the next environment.
- **Effort:** low. **Verify:** staging deploy under constant load shows `HTTPCode_ELB_502_Count` = 0.

---

## 3. P2 items (detail, condensed)

| N-ID | Problem → solution | Evidence | Effort | Risk of change | Verify |
|---|---|---|---|---|---|
| **N-14** [K-F5] | One account; dev creates the OIDC provider, so destroying dev breaks staging/prod deploys; shared quotas (EIPs 3+1+1 = default 5) → AWS Organizations with dev/staging/prod accounts, or at least an `account-bootstrap` root (OIDC provider, state bucket, KMS) | [environments/dev/main.tf:100](ecommerce-infrastructure/terraform/environments/dev/main.tf#L100) | medium | moving providers between states needs `import`/`moved` | `terraform destroy` in dev leaves staging deploys working |
| **N-15** [P2-2] | Captured amount ≠ order total only logged → publish a mismatch outcome; the saga goes to MANUAL_REVIEW | [payment-service.ts:260-262](ecommerce-payment-service/src/payments/payment-service.ts#L260-L262) | low | contract change (new field/event: minor) | payment test with a mismatched webhook amount |
| **N-16** [P2-3] | Pay-and-cancel race → MANUAL_REVIEW → handle `OrderCancelled` in `CONFIRMING_*` as refund + return, or forbid customer cancel once a payment session exists | [decide.ts:183-238](ecommerce-saga-orchestrator/src/saga/decide.ts#L183-L238) | medium | a saga state-machine change; extend decide tests first | new decide + flow tests |
| **N-17** [P2-4, P2-5] | Payment timeout doesn't expire the provider session (TODO); order orphaned `PENDING` after STARTED gives up → expire-session command (or rely on Stripe `expires_at` and fix the docs); send `OrderStatusTransitionRequested(FAILED)` on give-up | [decide.ts:155](ecommerce-saga-orchestrator/src/saga/decide.ts#L155), [:88-92](ecommerce-saga-orchestrator/src/saga/decide.ts#L88-L92) | low | — | decide tests |
| **N-18** [K-F8, P2-8] | One tasks SG for all, egress 0.0.0.0/0, plain HTTP inside the VPC, six DBs on one RDS → per-service SGs + DB ingress per SG; an egress allowlist; Service Connect TLS if required; later split payment/saga DBs | [platform/main.tf:101-128](ecommerce-infrastructure/terraform/modules/platform/main.tf#L101-L128) | medium | missing a rule = an outage; do it in dev with traffic | connectivity matrix test |
| **N-19** [P2-9, J-F7, J-F8, J-F9, S-8, S-9] | Actions by tag; base images by tag; no gitleaks in CI; no image scan/SBOM; no Dependabot → SHA pins (deploy actions first), digest pins, a gitleaks job / push protection, Trivy + provenance, Dependabot for actions/npm/pip/docker | all workflows/Dockerfiles | low | update churn | Dependabot PRs appear; a planted test secret is blocked |
| **N-20** [L-F4, L-F5] | "Safe" command change can DLQ if the sender re-pins first; OpenAPI synced from working trees without a source commit → document "owner/server deploys first"; record `{repo, commit}` per synced OpenAPI; sync only from `main`/tags | VERSIONING.md, [sync-openapi.mjs](ecommerce-contracts/scripts/sync-openapi.mjs) | low | — | review |
| **N-21** [M-F3, M-F4] | No correlation forwarding on HTTP; the saga uses `saga.id`; no metrics/dashboards/tracing → forward `x-correlation-id` in clients; store the request's correlation id on the saga; EMF business metrics (checkout funnel, saga states, refunds pending, notification failures); dashboards; later OTel + ADOT (envelope `traceparent` = contracts release) | [engine.ts:136](ecommerce-saga-orchestrator/src/saga/engine.ts#L136), grep of clients | medium–high | log volume/cost | one checkout traceable by one id |
| **N-22** [K-F11] | DB roles via manual SQL; no rotation; `sslmode=require` → a codified bootstrap task; RDS IAM auth or rotation; `verify-full` + the RDS CA | deployment.md §5–6 | medium | auth changes can lock services out | bootstrap re-run is idempotent; TLS verify test |
| **N-23** [K-F12] | CPU-only autoscaling for consumers → backlog-per-task target tracking for inventory/notification/saga | service module | low | scaling oscillation; tune | load test |
| **N-24** [P2-10, S-12] | Order never run on real DocumentDB → run its suite against a dev DocumentDB once (**requires an approved AWS apply**) | security-review S-12 | medium | cost | suite green |
| **N-25** [P2-7, K-F9, L-F9, K-2 note] | Docs disagree with code (saga states/tables, checklist open items, deployment.md variables, envelope description, "consumer extends visibility") → one docs pass; generate the state diagram from `SAGA_STATES` | PHASE-A-1 §4, A-2 | low | — | review |
| **N-26** [J-F10] | Generated workflows can drift unnoticed → run `generate-workflows.py --check` in the nightly, or replace generation with central reusable workflows called `@sha` | [generate-workflows.py](ecommerce-infrastructure/scripts/generate-workflows.py) | low–medium | — | nightly fails on a hand edit |
| **N-27** [M-F9, J-F13, L-F8] | Tests missing for: pay/cancel race, migration compatibility (old code + new schema), system load, all `down` migrations, response conformance outside Inventory → add per M-1 §3 | M-1 | medium | CI time | the new tests run in CI |
| **N-28** [P2-12] | `POST /api/v1/payments/intent` (service role) under a public path → move to `/internal/v1/payments/intent` (ALB-blocked); update the saga client and the stack paths | [routes.ts:39](ecommerce-payment-service/src/api/routes.ts#L39) | low | coordinated deploy: payment serves both paths first | public request → 404 |
| **N-33** [Phase E §5] | [AdminOperations.tsx:203](ecommerce-frontend/src/pages/admin/AdminOperations.tsx#L203) says "Refund it from Payments … no automated flow yet", but the saga refunds automatically. A manual refund makes the saga's refund `NOT_REFUNDABLE` → MANUAL_REVIEW (money stays safe thanks to the refund cap) → fix the text; warn/block payment refunds while the order is `CANCELLATION_PENDING`/`REFUND_PENDING`; document full refund = cancel the order, partial/goodwill = Payments | AdminOperations.tsx | low | — | admin UI test |

## 4. P3 items

| N-ID | Content | Repos |
|---|---|---|
| **N-29** [L-F7, L-F10] | `compat` compares error bodies/`code` enums and `security`; `deprecated: true` + `Deprecation`/`Sunset` headers when v2 appears; declare `x-correlation-id` | contracts, services |
| **N-30** [K-F13] | ALB/CloudFront/WAF logs (WAF with header redaction), VPC Flow Logs; org guardrails (CloudTrail, GuardDuty, Config, Access Analyzer, budgets). **Guardrails are mandatory before the first customer** even though they sit outside this repo | infrastructure, AWS org |
| **N-31** [K-F7, K-F14, J-F15, M-F8] | `required_version >= 1.11`; commit module lock files; align log redaction (product nested keys, inventory list); secret recovery window 0 in dev; ECR keep-30 = ~15 deploys; `DLQ_NAMES` from a module output; separate migrate task role; SPA function dot paths; CMK for cross-account snapshots; backend Docker layer cache; `persist-credentials: false`; `if: true` leftover; `fmt` once; bind local DB ports to 127.0.0.1; jose 5 vs 6; delete `.gitleaks-probe/` when done | various |
| **N-32** [P2-11, P3 list] | Document as accepted: 15-min access tokens stay valid after logout; at-least-once email can duplicate on crash; refresh-token reuse revokes the session (frontend mitigates with Web Locks; an optional grace window) | auth, notification, docs |

## 5. Mandatory vs optional

**Mandatory**, by gate:

| Gate | Items |
|---|---|
| Before merging `phase7` to `main` | N-08, N-09 |
| Before the first AWS apply (dev) | N-01, N-04, N-05, N-06, N-07, N-12, N-14 (decision), N-22 (codify bootstrap), N-19 (at least the deploy actions pinned) |
| Before the first customer | N-02, N-03, N-10, N-13, N-15, N-24, N-33, N-21 (minimal: correlation forwarding + checkout/saga metrics), N-30 (guardrails), a load test, measured RTO/RPO |
| Before the first v2 message | N-11 |

**Optional preferences** (valuable, but you can ship without them): N-16 (the race already fails safe), N-17, N-18 (beyond
basic SG hygiene), N-20, N-21 tracing, N-23, N-25–N-28, all P3 except the N-30 guardrails.

## 6. What not to change (strong as is)

The pure saga `decide()` + persist-then-publish; outbox + idempotent consumers that re-answer; single-statement no-oversell
reservations; "money truth wins" + bounded refunds + reconciliation; the saga startup drain; contract-first messages with
directional compat and hash-locked vendoring; strict owners / tolerant readers; liveness ≠ readiness; logger-level redaction;
no secrets in Terraform/state/CI; OIDC per repo + environment; hardened ECS task settings; one-origin CloudFront design.
Changes in §2–4 are deliberately **small and local**. None requires re-architecting or merging repositories.
