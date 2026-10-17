# Phase A.5: Confirmed Architectural Gaps and Risks (Preliminary)

Ranked by the plan's scale: **P0** = critical security / money / data loss, **P1** = major reliability or
deployment risk, **P2** = maintainability, operations, coverage, **P3** = optional.

**No P0 issue was found.** The money and stock paths (idempotency, webhook verification, refund caps, oversell
protection) are carefully built. The most serious problems sit where nothing has been run yet: AWS alerting,
deployment wiring, and one saga relay failure mode.

Phase N will expand this into the full backlog. Nothing here was fixed, and no repository was modified.

---

## P1-1: CloudWatch alarms cannot notify anyone (alarm topic uses the AWS-managed SNS key)

- **Status:** CONFIRMED (config + AWS docs). Not observed, because AWS was never applied.
- **Evidence:** [platform/main.tf:207-211](ecommerce-infrastructure/terraform/modules/platform/main.tf#L207-L211) sets
  `kms_master_key_id = "alias/aws/sns"` on the `alarms` topic. Every alarm (ALB 5xx, service, DB, and the messaging
  module's DLQ and queue-age alarms via `alarm_actions = var.alarm_topic_arns`,
  [messaging/main.tf:215](ecommerce-infrastructure/terraform/modules/messaging/main.tf#L215)) publishes to it.
- **Why it matters:** CloudWatch alarm actions cannot publish to an SNS topic encrypted with the AWS-managed key,
  because that key's policy can't be changed to allow `cloudwatch.amazonaws.com`. The alarms would go to ALARM
  state and nobody would be emailed. That includes "messages in a DLQ" and "money in manual review".
  `terraform test` with a mocked provider cannot catch this.
- **Fix (low effort):** use a customer-managed KMS key whose key policy allows `cloudwatch.amazonaws.com` (and
  `sns.amazonaws.com`) `kms:Decrypt` + `kms:GenerateDataKey*`, or leave the alarm topic unencrypted (it carries no
  customer data). The service event topics can keep `alias/aws/sns`, since only services with IAM publish there.
- **Verify:** after the first dev apply, run `aws cloudwatch set-alarm-state --alarm-name <dlq alarm> --state-value ALARM --state-reason test`
  and confirm the email arrives. Add this to the runbook drill log.

## P1-2: One permanently failing saga outbox row stops ALL saga messages

- **Status:** CONFIRMED (code). No test found for this case.
- **Evidence:** [saga outbox-relay.ts:61-93](ecommerce-saga-orchestrator/src/messaging/outbox-relay.ts#L61-L93).
  Rows are selected `ORDER BY seq`. On the first send error the loop returns `again: false` (line 82). The failing row
  is always the oldest unpublished row, so every later tick hits it first and stops again. Rows of **other**
  sagas behind it are never sent. Nothing caps `attempts` and nothing raises an alert.
- **Trigger examples:** a wrong or missing queue name for one target (the git log shows exactly this class of
  bug: "Saga gets the notification-commands queue name"), an IAM deny on one queue, or a body over 256 KB.
- **Impact:** every checkout stalls. Timeouts fire, but their compensation commands go to the same stuck
  outbox, so sagas pile up toward `MANUAL_REVIEW` while no command or event leaves the service.
- **Fix (medium):** keep per-saga ordering but isolate failures. On error, record `attempts`/`last_error`/
  `next_attempt_at` and `continue` with rows of other sagas (exclude sagas whose head row is failing). After N
  attempts mark the row `failed` and alert via a metric/log alarm. The Inventory, Auth and Payment relays use the same
  stop-on-first-error loop with a single destination, so their exposure is smaller (mostly oversize payloads).
  The Order relay is already isolated per document (lease).
- **Verify:** an integration test that inserts one row with a nonexistent queue plus one valid row of another
  saga, then asserts the valid one is published.

## P1-3: Repository names do not match what Terraform OIDC and the E2E workflow expect

- **Status:** CONFIRMED (config).
- **Evidence:** GitHub remotes are `github.com/david150383/cc-ecommerce-<name>` (`git remote -v`). The trust
  policy uses `repo:${owner}/ecommerce-${name}:environment:${env}`
  ([stack/main.tf:313](ecommerce-infrastructure/terraform/modules/stack/main.tf#L313),
  [github-oidc/main.tf:92](ecommerce-infrastructure/terraform/modules/github-oidc/main.tf#L92)).
  [e2e.yml:25](ecommerce-infrastructure/.github/workflows/e2e.yml#L25) clones `ecommerce-$r`.
  `ecommerce-contracts` has **no remote** at all.
- **Impact:** `AssumeRoleWithWebIdentity` would be denied for every deploy, and the nightly E2E would fail at clone.
  If the repos are private, the E2E clone also needs a token.
- **Decision (2026-10-16):** the `cc-` prefix is **intentional** (it separates these repos from your other `ecommerce-*` repos).
- **Fix (low):** add a `repo_prefix` Terraform variable (default `cc-ecommerce-`) and a `REPO_PREFIX` env in `e2e.yml`.
  Keep the clone directories named `ecommerce-*` so compose's build contexts still work. Create the
  `cc-ecommerce-contracts` remote.

## P1-4: Terraform env-var changes never reach running tasks after the first apply

- **Status:** CONFIRMED (Terraform semantics + workflow code).
- **Evidence:** `lifecycle { ignore_changes = [container_definitions] }` on both task definitions
  ([service/main.tf:289-292](ecommerce-infrastructure/terraform/modules/service/main.tf#L289-L292), [:319-321](ecommerce-infrastructure/terraform/modules/service/main.tf#L319-L321)).
  The deploy job copies the **latest live** task definition and replaces only the image
  ([deploy-environment.yml:74-77](ecommerce-auth-service/.github/workflows/deploy-environment.yml#L74-L77)).
- **Impact:** add a queue name, change `MAX_ACTIVE_CHECKOUTS`, rotate a secret ARN in `stack/main.tf`, and
  `terraform apply` reports no change while ECS keeps the old config forever. Ownership is split, so neither side
  carries config changes.
- **Fix (medium):** make one owner. Options: (a) Terraform owns the task definition and CI passes the image tag as a
  variable (`terraform apply -var image_tag=$SHA`, which needs a plan/approval step in CD); (b) CI owns it, with the
  env/secrets list committed in the service repo (e.g. a `taskdef.json` template rendered in CI); (c) keep the
  split, but have CI read env/secrets from an SSM parameter that Terraform writes.
- **Verify:** change one env var in Terraform, apply in dev, deploy, then check `aws ecs describe-task-definition`.

## P1-5: Deploys rebuild the image per environment instead of promoting one artifact

- **Status:** CONFIRMED (workflow code).
- **Evidence:** each environment job runs its own `docker buildx build … --push` into **that environment's** ECR
  ([deploy-environment.yml:45-52](ecommerce-auth-service/.github/workflows/deploy-environment.yml#L45-L52)). Base
  images are tags (`node:24-alpine`, `python:3.14-slim`), not digests (open finding S-8).
- **Impact:** what runs in production is not byte-for-byte what passed staging. Builds are also slow (arm64 under
  QEMU, three times per commit).
- **Fix (medium):** build once (job 1), push to one ECR (or replicate), record the **digest**, and deploy
  `repo@sha256:…` in every environment. Pin base images by digest with Renovate/Dependabot to update them. Add an
  image scan and SBOM/provenance at the build step.

## P1-6: CI on `main` can cancel the deploy's own CI (concurrency group collision)

- **Status:** PLAUSIBLE. Needs one real push to confirm.
- **Evidence:** [ci.yml:12-14](ecommerce-auth-service/.github/workflows/ci.yml#L12-L14) uses
  `group: ci-${{ github.ref }}`, `cancel-in-progress: true`, and triggers on `push: [main]`. The same file is
  called by `deploy.yml` on the same push. In a called workflow, `github.*` refers to the caller, so both runs
  compute `ci-refs/heads/main`.
- **Fix (low):** `group: ci-${{ github.workflow }}-${{ github.ref }}` (the called copy sees `github.workflow == "deploy"`),
  or drop `push: [main]` from `ci.yml`, since `deploy.yml` already runs CI on main.

## P2 items

| ID | Problem | Evidence | Fix | Effort |
|---|---|---|---|---|
| P2-1 | `deploy.yml` runs on every push to `main`, but AWS does not exist yet, so every main push would be red once `phase7` is merged | [deploy.yml:8-11](ecommerce-auth-service/.github/workflows/deploy.yml#L8-L11) | Until the first apply: `workflow_dispatch` only, or a job-level `if: vars.AWS_DEPLOY_ROLE_ARN != ''` | low |
| P2-2 | Captured amount ≠ order total is only **logged**; the payment is still marked SUCCEEDED and the order confirmed | [payment-service.ts:260-263](ecommerce-payment-service/src/payments/payment-service.ts#L260-L263) | Publish a distinct outcome (or a flag) that sends the saga to `MANUAL_REVIEW` | low |
| P2-3 | Pay-and-cancel race ends in `MANUAL_REVIEW` (charged, order CANCELLED, stock deducted) instead of auto-refund | [decide.ts:183-216](ecommerce-saga-orchestrator/src/saga/decide.ts#L183-L216) ignores `OrderCancelled`; [order-command-handler.ts:29-33](ecommerce-order-service/src/messaging/order-command-handler.ts#L29-L33) acks invalid transitions | Have the saga treat `OrderCancelled` in `CONFIRMING_*` as "refund + return", or block customer cancel once a payment session exists. Add a decide test | medium |
| P2-4 | Payment timeout does not ask Payment/Stripe to expire the session (TODO at [decide.ts:155](ecommerce-saga-orchestrator/src/saga/decide.ts#L155)); the docs say it does | checkout-saga.md table | Add `PaymentExpireRequested` or rely on Stripe `expires_at` and fix the doc | low |
| P2-5 | Order created but its response lost, then 5 failed retries → saga `FAILED` with no cancel → orphan `PENDING` order | [decide.ts:88-92](ecommerce-saga-orchestrator/src/saga/decide.ts#L88-L92), [:391-393](ecommerce-saga-orchestrator/src/saga/decide.ts#L391-L393) | On give-up, send `OrderStatusTransitionRequested(FAILED)` by saga id, or have Order expire stale `PENDING` orders | low |
| P2-6 | Outbox relays hold a DB transaction (and row locks) open across network sends, for up to 50 rows | saga/inventory `outbox-relay.ts` | Claim rows (`locked_until`) in a short TX, send outside, mark in a second TX | medium |
| P2-7 | **Doc drift**: checklist still lists S-11 and the Inventory response schemas as open (both fixed); saga states/tables in the docs don't match the code; README says contracts deferred | [implementation-checklist.md](ecommerce-infrastructure/docs/architecture/implementation-checklist.md), PHASE-A-1 §4 | One docs pass; generate the state diagram from `SAGA_STATES` | low |
| P2-8 | One shared tasks security group: any task can reach any DB port; isolation is credentials-only. One RDS instance hosts all 6 DBs (shared blast radius, maintenance windows, connection limits) | [stack/main.tf:273](ecommerce-infrastructure/terraform/modules/stack/main.tf#L273), [data/main.tf:118](ecommerce-infrastructure/terraform/modules/data/main.tf#L118) | Per-service SG + DB ingress by SG; later split Payment/Saga onto their own instance | medium |
| P2-9 | GitHub Actions pinned to floating tags (`@v4`, `@v3`, `docker://…:1.7.7`) | all workflows | Pin to full commit SHAs + Dependabot for actions | low |
| P2-10 | Order on DocumentDB never tested against real DocumentDB (S-12, open per their review) | security-review.md | Run the suite against a dev DocumentDB once | medium |
| P2-11 | Refresh-token reuse revokes the whole session; a network error after the server rotated logs the user out. Mitigated in the frontend (Web Locks, no retry on network error) | [auth.service.ts:196-233](ecommerce-auth-service/src/modules/auth/auth.service.ts#L196-L233), [session.ts:72-117](ecommerce-frontend/src/auth/session.ts#L72-L117) | Accept, or add a short grace window for the immediately-previous token | low |
| P2-12 | `POST /api/v1/payments/intent` (service-only) is publicly routable; only the role check protects it | [routes.ts:39](ecommerce-payment-service/src/api/routes.ts#L39) | Move to `/internal/v1/payments/intent` | low |

## P3 items

- Access tokens (15 min) stay valid after logout or a password reset. This is the stateless-JWT trade-off; fine at this TTL.
- Notification email is at-least-once: a crash between SMTP send and marking `SENT` sends a duplicate.
- Inventory uses `jose` 5 while the other services use `jose` 6.
- Local DB ports bind to all interfaces.
- Infra CI runs `terraform fmt` five times.
- `.gitleaks-probe/` (with a planted secret file) sits in the workspace root. Keep it out of any repo or delete it.

## What is notably strong (so you know what not to "fix")

- **Pure `decide()` + persist-then-publish**: every saga rule is unit-testable, and "state before action" is structural.
- **"Duplicates re-answer"**: consumers don't redo work but re-emit the result, so a re-sending saga is never stuck.
- **Inventory no-oversell**: a single conditional UPDATE per line, SKU-ordered locks, a savepoint, and DB CHECK constraints.
- **Payment**: amount only from Order, raw-body HMAC with a timestamp window, dedupe row in the same TX,
  "money truth wins", bounded refunds, reconciliation.
- **Saga startup drain** before judging deadlines: a subtle crash-recovery bug, already handled and tested.
- **No credentials in any PR-triggered job**; OIDC roles scoped to repository + environment.

## Unresolved questions for you

1. ~~Is the `cc-` prefix intentional?~~ Yes (answered 2026-10-16).
2. Are GitHub Environments (`dev`, `staging`, `production`) and required reviewers configured on GitHub? This can't
   be seen from the repos.
3. ~~Merge `phase7`?~~ No: kept unmerged on purpose, no deployment for now (answered 2026-10-16).
4. ~~Run the test suites?~~ No: analysis stays read-only (answered 2026-10-16).
