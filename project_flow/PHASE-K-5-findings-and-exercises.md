# Phase K-5: Findings, Fix Order, Exercises, Acceptance Criteria

Nothing here was observed in AWS (nothing exists there). "CONFIRMED" means: the configuration is certain, and the
consequence follows from it or from documented AWS behavior.

## 1. Findings (Terraform / AWS / IAM)

| ID | Priority | Finding | Status | Evidence | Fix | Effort |
|---|---|---|---|---|---|---|
| **K-F1** | **P1** | **The WAF can be bypassed**: the ALB admits the *global* CloudFront origin-facing prefix list, with no secret header and path-only rules. Anyone's own CloudFront distribution can reach the API around your WAF (auth rate limits, managed rules) | CONFIRMED config + AWS behavior | [platform/main.tf:74-91](ecommerce-infrastructure/terraform/modules/platform/main.tf#L74-L91), [frontend/main.tf](ecommerce-infrastructure/terraform/modules/frontend/main.tf) `custom_origin_config` without `custom_header` | CloudFront **VPC origin** + internal ALB, or a secret `X-Origin-Verify` header required by every ALB rule (rotated). Add a test | low–medium |
| **K-F2** | **P1** | **Notification's DLQ monitor and admin dead-letters page get AccessDenied in AWS**: IAM grants nothing on DLQ ARNs. Combined with P1-1, dead letters would be invisible | CONFIRMED code vs IAM | [dlq-monitor.ts:29-60](ecommerce-notification-service/src/messaging/dlq-monitor.ts#L29-L60), [messaging/main.tf:65](ecommerce-infrastructure/terraform/modules/messaging/main.tf#L65) | Add DLQ read actions for notification in `service_access` | low |
| K-F3 (= P1-1) | **P1** | Alarm topic encrypted with `alias/aws/sns`, so CloudWatch can't publish (no alarm ever arrives) | CONFIRMED config + AWS docs | [platform/main.tf:207-211](ecommerce-infrastructure/terraform/modules/platform/main.tf#L207-L211) | CMK with a CloudWatch-friendly key policy, or no encryption on that topic | low |
| K-F4 (= P1-4) | **P1** | Task-definition ownership split: Terraform env/secret changes never reach ECS | CONFIRMED | [service/main.tf:289-292](ecommerce-infrastructure/terraform/modules/service/main.tf#L289-L292) | One owner (PHASE-A-5 options) | medium |
| **K-F5** | P2 | One account for all environments; **dev owns the account-wide GitHub OIDC provider**, so `terraform destroy` in dev (unprotected by design) breaks staging/prod deploys. Shared human blast radius and quotas (Elastic IPs: 3 + 1 + 1 = exactly the default 5) | CONFIRMED config | [environments/dev/main.tf:100](ecommerce-infrastructure/terraform/environments/dev/main.tf#L100) | Separate accounts (Organizations), or at least an `account-bootstrap` root for the OIDC provider, state bucket and KMS keys | medium |
| **K-F6** | P2 | DB connection budget: ~60 connections per "one task each", ×2 during rolling deploys; dev `db.t4g.micro` allows only ~80–110; prod at max scale ≈ 600; fixed 300 alarm threshold | PLAUSIBLE (depends on exact `max_connections`) | pool defaults in each service (K-2 §2.1), [data/main.tf:202](ecommerce-infrastructure/terraform/modules/data/main.tf#L202) | Explicit small pools via env, per-class thresholds, RDS Proxy for prod | low |
| K-F7 | P3 | `required_version = ">= 1.9"` but `use_lockfile` needs Terraform ≥ 1.10/1.11 | CONFIRMED | each `environments/*/main.tf:7`, `backend.hcl.example` | `>= 1.11` (or `~> 1.16`) | low |
| K-F8 | P2 | Network isolation is coarse: one `tasks` SG for all services (any task → any task's 4001–4007, any task → both DBs); egress to everything; plain HTTP inside the VPC | CONFIRMED | [platform/main.tf:101-128](ecommerce-infrastructure/terraform/modules/platform/main.tf#L101-L128) | Per-service SGs and DB ingress per SG; egress allowlist; Service Connect TLS if required | medium |
| K-F9 | P3 | deployment.md step 7 lists 2 GitHub variables; the workflows need 6 (+3 for the frontend) | CONFIRMED | deployment.md vs `deploy-environment.yml` | Document all of them from the stack outputs | low |
| **K-F10** | P2 | **IAM is effectively untested**: the messaging module (all queue policies + per-service IAM) has no `terraform test`; service tests mock `aws_iam_policy_document` with empty statements; Floci doesn't enforce IAM. K-F2 is the result | CONFIRMED | [service.tftest.hcl:14-16](ecommerce-infrastructure/terraform/modules/service/tests/service.tftest.hcl#L14-L16), no `messaging/tests/` | Messaging tests asserting policy JSON; post-apply `simulate-principal-policy` checks in dev | low |
| K-F11 | P2 | Per-service DB roles are created by manual bootstrap SQL; there is no rotation; clients use `sslmode=require` (no cert verification) | CONFIRMED | deployment.md step 5–6 | Codified bootstrap task; RDS IAM auth or rotation; `verify-full` with the RDS CA | medium |
| K-F12 | P2 | Autoscaling is CPU-only, including queue consumers | CONFIRMED | [service/main.tf](ecommerce-infrastructure/terraform/modules/service/main.tf) `aws_appautoscaling_policy.cpu` | Backlog-per-task target tracking for consumers | low |
| K-F13 | P3 | No ALB, CloudFront, WAF or VPC flow logs; account guardrails (CloudTrail, GuardDuty, Config) out of scope | CONFIRMED | — | Logging configs + an org-level security baseline | medium |
| K-F14 | P3 | Small items: dev secret recovery window blocks quick re-create; ECR lifecycle (30 images) = ~15 deploys of rollback; `DLQ_NAMES` hand-built in `stack`; migrate task reuses the service task role; SPA function skips paths with a dot; AWS-managed keys block cross-account snapshot copy; "consumer extends visibility" doc claim not implemented | CONFIRMED | K-1…K-3 | housekeeping | low |

## 2. What is strong (don't "fix" these)

- One-origin CloudFront design (no CORS, first-party cookies); OAC + `SourceArn`-scoped bucket policy; SPA rewrite on
  the site behavior only; a strict CSP and HSTS.
- Private subnets, no public IPs, the default SG neutralized, VPC endpoints for all AWS traffic.
- ECS hardening: non-root (validated, with a negative test), read-only root FS, init process, no exec, circuit breaker
  with rollback, 100 % minimum healthy, readiness-based ALB health checks.
- Secrets: zero values in Terraform or state; RDS-managed master passwords; per-service secret readable only by its execution role.
- Least-privilege IAM by construction: per-service messaging policy, queue policies bound to topic ARNs, deploy roles bound
  to repo + environment with `PassRole` restricted to ECS and own roles, and `RunTask` restricted to own migrate family.
- Mocked-provider tests that lock in design guarantees, including negative tests (`expect_failures`).
- The same messaging module applied locally to Floci and (designed) to AWS: local topology = real topology.

## 3. Suggested fix order before any first apply (you have said: no deploy for now)

1. **Edge:** K-F1 (VPC origin or secret header).
2. **Observability actually works:** K-F3 (alarm KMS), K-F2 (DLQ IAM), K-F10 (messaging policy tests that would have caught K-F2).
3. **Deploy correctness:** K-F4 (task-def ownership) together with J-F1/J-F3 (build once, idempotent publish).
4. **Account layout:** K-F5 decision (separate accounts, or a bootstrap root), K-F7.
5. **Capacity:** K-F6 pool sizes before load arrives.
6. Then the P2/P3 hardening at leisure.

## 4. How each fix would be verified (when you choose to)

| Fix | Offline check (no AWS) | First-apply check (dev, with approval) |
|---|---|---|
| K-F1 | `terraform test` asserting the custom header on the origin and an `http_header` condition on every listener rule | From your laptop: `curl https://origin-api.dev…/api/v1/products` → 403; through the shop domain → 200 |
| K-F2 | messaging test: notification policy contains the DLQ ARNs | `aws iam simulate-principal-policy --policy-source-arn <notification task role> --action-names sqs:ReceiveMessage --resource-arns <dlq arn>` → allowed |
| K-F3 | test that the alarm topic's KMS key isn't the AWS-managed SNS key | `aws cloudwatch set-alarm-state --alarm-name dev-ecommerce-alb-5xx --state-value ALARM --state-reason drill` → email arrives |
| K-F4 | — | change one env var in `stack`, apply, deploy, `aws ecs describe-task-definition` shows it |
| K-F6 | arithmetic per environment in a table in the repo | `SELECT count(*) FROM pg_stat_activity` during a full rolling deploy |

## 5. Hands-on exercises (reading; the optional ones are offline and touch no AWS)

1. **Draw the request path** for `POST /api/v1/auth/login` from the browser to the auth task, naming every
   component, the security-group rule and the WAF rule involved. Then draw the **attacker's** path for K-F1.
2. **Blast radius:** for `payment-service`, list what its task role, execution role and deploy role can each do,
   using only [github-oidc/main.tf](ecommerce-infrastructure/terraform/modules/github-oidc/main.tf),
   [service/main.tf](ecommerce-infrastructure/terraform/modules/service/main.tf) and
   [messaging/main.tf](ecommerce-infrastructure/terraform/modules/messaging/main.tf).
3. **Plan reading (thought experiment):** if you changed `fifo_queues` to include `payment-commands`, which resources would
   show `-/+` in a plan, and what migration would you need to avoid losing in-flight refund commands?
4. **Connection math:** with your chosen pool sizes, fill a table of connections at rest, during a full deploy and at
   max scale for dev, staging and prod.
5. *(Optional, offline)* `cd ecommerce-infrastructure/terraform/modules/network && terraform console`, then evaluate
   `cidrsubnet("10.20.0.0/16", 4, 8)` to see the first private subnet. No credentials needed, nothing created.
6. **Design:** sketch an `environments/account-bootstrap` root (OIDC provider, state bucket, alarm KMS key) and the order
   in which you'd apply it versus the environment roots.

## 6. Interview-style questions

- *Why is "ALB allows only the CloudFront prefix list" not enough?* The list covers all customers' distributions; you
  must also prove the request came from **your** distribution (secret header, or VPC origin).
- *Execution role vs task role?* The execution role is used by ECS to start the task (pull the image, fetch secrets, write logs).
  The task role is used by your code at runtime (SNS/SQS). Mixing them gives the app permissions it doesn't need, or
  leaves ECS unable to start it.
- *Why `manage_master_user_password`?* RDS generates and rotates the password in Secrets Manager, so it never appears in
  Terraform state or variables.
- *What does `ignore_changes = [container_definitions]` trade off?* CI can deploy new images without Terraform
  reverting them, but Terraform also stops delivering env/secret changes.
- *Why are interface endpoints worth their hourly cost?* AWS traffic stays private, NAT data charges drop, and tasks
  work even if the NAT (or its AZ) is down, except for third parties.
- *Why can't `terraform test` with mocks catch K-F2 or K-F3?* Mocks don't evaluate IAM or KMS policies. Only real AWS
  (or a dedicated policy-assertion test) does.

## 7. Phase K summary

**Topics covered:** Terraform concepts in use; module graph; environment matrix; network and edge (VPC, NAT,
endpoints, SGs, ALB, CloudFront, S3, WAF); ECS service internals; RDS/DocumentDB; SNS/SQS module; IAM identities,
blast radius; secrets lifecycle; encryption; state, backends, accounts; first-apply review; Terraform command do/don'ts;
drift ownership; cost drivers.

**Files examined:** all `modules/*/main.tf` (+ messaging `variables.tf`), all `environments/*/main.tf`,
`backend.hcl.example`, `terraform.tfvars.example`, every `tests/*.tftest.hcl` (run names and assertions), `deployment.md`,
`runbooks.md` (rollback), `dlq-monitor.ts`, service DB pool code, every AWS SDK command used in `src/` (grep).

**Commands executed (read-only):** `cat`, `sed`, `grep`, `diff` between environment roots, `git ls-files`. **No**
`terraform` command and no AWS call.

**Unresolved questions for you:**
1. Single AWS account for all environments (as designed), or separate accounts?
2. For K-F1: are you open to CloudFront VPC origins (internal ALB), or do you prefer the secret-header approach?
3. Is plain HTTP inside the VPC acceptable for this project, or do you want TLS for service-to-service traffic?

## 8. Acceptance criteria for Phase K

- You can explain every module's purpose and the dependency graph in §2 of K-0.
- You can trace a request from the browser to a task and name each control that applies, including why K-F1 bypasses some of them.
- You can state, for any service, what its execution, task and deploy roles allow, and what a compromise of each would expose.
- You can explain why secrets never touch Terraform state here, and how a secret rotation reaches a running task.
- You can read a `terraform plan` and say which symbols require a migration plan for stateful resources.
- You can explain K-F2, K-F3 and K-F5 with file and line, and say how you'd verify each fix.

Next options: **Phase L** (contracts: OpenAPI, JSON Schema, AsyncAPI, compatibility) or **Phase B** (Git, structure,
configuration). Phase M (integration testing, observability, production readiness) builds on J and K.
