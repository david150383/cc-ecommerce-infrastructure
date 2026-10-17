# Codebase Mentor Notes: Start Here

These notes explain the e-commerce microservices platform **as it actually exists on disk**. They live in the
workspace root, outside every repository, so no repository was changed to produce them.

## What was analyzed

| Item | Value |
|---|---|
| Date of analysis | 2026-10-16 |
| Location | `/Users/sohin/new-ecommerce-microservices/` (10 sibling git repositories) |
| Branch analyzed | **`phase7`** in every repository (the checked-out branch, working trees clean) |
| `phase7` vs `main` | `phase7` is 4–14 commits ahead of local `main` in every repo |
| `main` vs GitHub | local `main` is 2–11 commits ahead of `origin/main` (remotes are `github.com/david150383/cc-ecommerce-*`) |
| What GitHub currently has | `origin/main` contains **only `ci.yml`** in each repo, with no deploy workflows yet |
| `ecommerce-contracts` | exists locally with tags `v1.0.0`–`v1.3.0`, **no git remote** |

## What was and was not done

- **Read:** source, migrations, tests (names and selected bodies), Dockerfiles, compose files, every workflow under
  `.github/workflows/`, Terraform modules, and the architecture docs in `ecommerce-infrastructure/docs/architecture/`.
- **Not executed:** no tests, builds, `docker compose`, `terraform plan/test`, or CI runs. Every statement
  like "tests cover X" means *a test with that name exists*, not that it passed. The project's own docs claim
  many things were verified; those claims are quoted as **claims**.
- **No GitHub access:** `gh` is not installed, so no workflow run history was inspected. Whether CI is green on
  GitHub is **unknown**.
- **Secrets:** no secret values were printed. The workspace root contains `.gitleaks-probe/leak.env` (a planted
  file used to prove the secret scanner works, per `security-review.md`). It was not opened.

## Confidence labels used throughout

| Label | Meaning |
|---|---|
| **CONFIRMED (code)** | Read in the source/config; the behavior follows directly from it |
| **CONFIRMED (config + AWS docs)** | The config is certain; the consequence relies on documented AWS behavior, not observed |
| **PLAUSIBLE** | Strong inference; needs a run or a GitHub/AWS check to be sure |
| **CLAIM (docs)** | Stated in the project's docs, not independently verified here |

## Phase A files (read in this order)

1. [PHASE-A-1-architecture.md](PHASE-A-1-architecture.md): system diagram, repository matrix, dependency map, database ownership
2. [PHASE-A-2-checkout-saga.md](PHASE-A-2-checkout-saga.md): the real checkout state machine, sequence, every failure and compensation path
3. [PHASE-A-3-local-dev-docker.md](PHASE-A-3-local-dev-docker.md): compose architecture, Dockerfile pattern, local vs CI vs production
4. [PHASE-A-4-cicd-inventory.md](PHASE-A-4-cicd-inventory.md): every workflow, the command inventory, pipeline order
5. [PHASE-A-5-risks-and-gaps.md](PHASE-A-5-risks-and-gaps.md): confirmed gaps and risks, ranked, with evidence and fixes
6. [PHASE-A-6-decisions-and-checklist.md](PHASE-A-6-decisions-and-checklist.md): the five most important architectural decisions, learning checklist, Phase A exercises

## Phases B–I files (structure and service deep-dives)

- [PHASE-B-git-dependencies-config-structure.md](PHASE-B-git-dependencies-config-structure.md): Git history and branches, safe merge plan, dependencies, config validation, folder conventions
- [PHASE-C-auth-and-product.md](PHASE-C-auth-and-product.md): token lifecycle, cookies/CSRF, Argon2id, JWKS rotation; catalog, search, price rules, ETags
- [PHASE-D-inventory-and-order.md](PHASE-D-inventory-and-order.md): stock adjustments, reservations, enum migrations; order pricing (BigInt, allocation, tax), DocumentDB guards
- [PHASE-E-payment-and-financial-correctness.md](PHASE-E-payment-and-financial-correctness.md): money invariants I1–I9, provider adapters, webhook pipeline, refunds, reconciliation, the stale admin-refund instruction (N-33)
- [PHASE-F-messaging-and-notification.md](PHASE-F-messaging-and-notification.md): SNS/SQS concepts with this platform's numbers, every message traced, the consumer loop, the Notification service
- [PHASE-G-saga-orchestrator-internals.md](PHASE-G-saga-orchestrator-internals.md): the 202 + polling API, seven concurrency mechanisms, worker lifecycle, HTTP result classification, operations
- [PHASE-H-frontend.md](PHASE-H-frontend.md): trust rule, HTTP/session layers, cart, the checkout flow in the browser, contract types, money formatting
- [PHASE-I-docker-deep-dive.md](PHASE-I-docker-deep-dive.md): Dockerfiles line by line, all images, .dockerignore, standalone compose, commands, an image security checklist

## Phase J files (CI/CD)

0. [PHASE-J-0-overview.md](PHASE-J-0-overview.md): Actions mental model, every keyword, trigger matrix, what green proves
1. [PHASE-J-1-node-service-ci.md](PHASE-J-1-node-service-ci.md): the six Node backends' `ci.yml`, line by line
2. [PHASE-J-2-other-ci.md](PHASE-J-2-other-ci.md): Product, Frontend, Contracts, Infrastructure CI and the nightly E2E
3. [PHASE-J-3-deploy-pipeline.md](PHASE-J-3-deploy-pipeline.md): `deploy.yml` / `deploy-environment.yml`, frontend variant, generator
4. [PHASE-J-4-commands-do-and-dont.md](PHASE-J-4-commands-do-and-dont.md): the use / caution / avoid table
5. [PHASE-J-5-security-model.md](PHASE-J-5-security-model.md): permissions, triggers, OIDC, Environments, pinning, state, rollback
6. [PHASE-J-6-troubleshooting.md](PHASE-J-6-troubleshooting.md): failure guide per stage (hypothetical errors)
7. [PHASE-J-7-independent-pipelines.md](PHASE-J-7-independent-pipelines.md): comparison, contracts flow, proposed standard, findings J-F1…F15, exercises

## Phase K files (Terraform, AWS, IAM, deployment security)

0. [PHASE-K-0-overview.md](PHASE-K-0-overview.md): Terraform concepts in use, layout, module graph, environment matrix, designed vs applied
1. [PHASE-K-1-edge-and-network.md](PHASE-K-1-edge-and-network.md): CloudFront, WAF, ALB, security groups, VPC, NAT, endpoints (incl. the WAF bypass K-F1)
2. [PHASE-K-2-compute-data-messaging.md](PHASE-K-2-compute-data-messaging.md): ECS service module, RDS/DocumentDB, connection budget, SNS/SQS module (incl. the DLQ IAM gap K-F2)
3. [PHASE-K-3-iam-and-secrets.md](PHASE-K-3-iam-and-secrets.md): every IAM identity, blast radius, secrets lifecycle, encryption
4. [PHASE-K-4-state-environments-operations.md](PHASE-K-4-state-environments-operations.md): state, accounts, first-apply review, plan/apply workflow, Terraform commands, cost drivers
5. [PHASE-K-5-findings-and-exercises.md](PHASE-K-5-findings-and-exercises.md): findings K-F1…F14, fix order, verification, exercises, acceptance criteria

## Phase L files (API contracts and compatibility)

0. [PHASE-L-0-overview.md](PHASE-L-0-overview.md): concepts, what lives where, contract-first messages vs code-first HTTP, release history
1. [PHASE-L-1-message-contracts.md](PHASE-L-1-message-contracts.md): envelope and schemas line by line, ownership, runtime validation, consumer-driven checks, vendoring
2. [PHASE-L-2-http-contracts.md](PHASE-L-2-http-contracts.md): OpenAPI per stack, drift tests, client coverage, API versioning
3. [PHASE-L-3-compatibility-and-evolution.md](PHASE-L-3-compatibility-and-evolution.md): compat rules, version bumps, expand → migrate → contract, deploy order, the `messageVersion` gap
4. [PHASE-L-4-findings-and-exercises.md](PHASE-L-4-findings-and-exercises.md): findings L-F1…F10, fix order, exercises, acceptance criteria

## Phase M files (integration testing, observability, troubleshooting, readiness)

0. [PHASE-M-0-overview.md](PHASE-M-0-overview.md): the test pyramid as implemented, cross-service scripts and drills, headline findings
1. [PHASE-M-1-integration-testing.md](PHASE-M-1-integration-testing.md): coverage per layer, gaps, designs for concurrency, duplicate, webhook, recovery and migration tests
2. [PHASE-M-2-observability.md](PHASE-M-2-observability.md): logs, correlation, health, metrics, alarms, tracing, a minimal design
3. [PHASE-M-3-troubleshooting-playbook.md](PHASE-M-3-troubleshooting-playbook.md): symptom → diagnosis → fix, with SQL and CLI
4. [PHASE-M-4-production-readiness.md](PHASE-M-4-production-readiness.md): scorecard, shutdown analysis, go-live checklist, findings M-F1…F9

## Phase N files (consolidated backlog)

0. [PHASE-N-0-backlog.md](PHASE-N-0-backlog.md): every finding merged into 32 items (N-01…N-32), each with problem, evidence, solution, effort, risk and verification; mandatory gates vs optional
1. [PHASE-N-1-roadmap-and-wrapup.md](PHASE-N-1-roadmap-and-wrapup.md): dependency graph, milestones 0–3, open decisions, the safe-change process, course wrap-up

## Next phases

**All phases A–N are complete.** The backlog to act on is PHASE-N-0 (33 items).
Ground rules (from you, 2026-10-16): read-only analysis, no tests run, nothing deployed, `phase7` stays unmerged.
