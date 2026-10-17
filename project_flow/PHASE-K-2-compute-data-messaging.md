# Phase K-2: Compute (ECS), Data (RDS, DocumentDB), Messaging (SNS/SQS)

## 1. The `service` module: one microservice on Fargate

File: [modules/service/main.tf](ecommerce-infrastructure/terraform/modules/service/main.tf) (559 lines). Instantiated
seven times by `stack` (`for_each = local.services`).

### 1.1 What one instance creates

| Resource | Purpose | Key settings |
|---|---|---|
| `aws_secretsmanager_secret` `<env>-ecommerce/<svc>` | Container for runtime secrets (JSON) | **Values never in Terraform**; set with `aws secretsmanager put-secret-value` |
| `aws_cloudwatch_log_group` `/ecs/<env>-ecommerce-<svc>` | stdout logs (pino JSON) | retention per env (14/30/90 days) |
| IAM **execution role** | What ECS needs to *start* the task | AWS managed `AmazonECSTaskExecutionRolePolicy` (ECR pull, logs) + `GetSecretValue` on **its own secret only** |
| IAM **task role** | What the *application* may do | the messaging module's per-service policy (topic publish / queue send / queue consume) |
| `aws_ecs_task_definition` (service) | The container spec | ARM64; `readonlyRootFilesystem`; `user = run_as` (1000:1000; product 10001); `initProcessEnabled` (tini as PID 1, so signals reach Node); `/tmp` volume; `secrets` = `valueFrom: <secretArn>:<KEY>::`; healthcheck `wget /health/live`; `stopTimeout = 30`; `ignore_changes = [container_definitions]` |
| `aws_ecs_task_definition` (migrate) | One-off migration container | image `:<tag>-migrate`, same secret, **same task role** (see note), no healthcheck |
| `aws_lb_target_group` (public services) | ALB → task IPs | `target_type = ip`, health check `/health/ready` 200, 15 s interval, deregistration delay 30 s |
| `aws_lb_listener_rule` ×⌈paths/5⌉ | Path routing on the shared listener | priority `100 + index*10 + chunk` |
| `aws_ecs_service` | Keeps N tasks running | `minimum_healthy_percent = 100`, `maximum_percent = 200`, circuit breaker with rollback, no exec, no public IP, Service Connect (`discovery_name` and `dns_name` = service name), `ignore_changes = [task_definition, desired_count]` |
| `aws_appautoscaling_*` | Scale out on CPU | target tracking **60 % average CPU**, scale-out cooldown 60 s, scale-in 300 s |
| Alarms | running tasks < min (5 min), memory > 85 %, target 5xx > 5 % (only above 20 req/min), p99 latency > 2 s | all → the alarm topic (which can't deliver: P1-1) |

### 1.2 How a task starts (execution sequence)

1. ECS picks a subnet and capacity provider (Spot in dev/staging), then creates an ENI in a private subnet with the `tasks` SG.
2. The **execution role** pulls `…/<svc>:<tag>` via the ECR endpoints + S3 gateway, and fetches each `secrets[]` key
   from Secrets Manager via its endpoint. **Secrets are read once, at start.** A rotated secret reaches running tasks only after a
   redeploy or task replacement.
3. Container env = `NODE_ENV=production`, `PORT`, the `stack` env map; the app's Zod/Pydantic config validates it and
   **refuses to boot** on invalid config (e.g. `PAYMENT_PROVIDER=mock` with `NODE_ENV=production`).
4. The Service Connect sidecar (Envoy) registers `auth-service:4001` etc. in the namespace. Other tasks call
   `http://order-service:4004`, exactly the URLs in `stack/main.tf`.
5. The container health check (`/health/live`) and the ALB check (`/health/ready`) must pass. During a deploy, old tasks drain
   only once the new ones are healthy (100 % minimum).

### 1.3 Observations

| # | Observation | Impact | Suggestion |
|---|---|---|---|
| a | **Initial image tag `bootstrap` doesn't exist** (by design: services sit at 0 tasks until the first CI deploy) | Every `running-tasks-low` alarm fires from the first apply onward | Expected. Document it, or create services with `desired_count = 0` until the first deploy |
| b | Migrate task **shares the task role**, so it holds the service's SNS/SQS permissions | Unneeded privilege for a short-lived job | Separate minimal task role (none needed) |
| c | Service-to-service traffic and ALB → task traffic is **plain HTTP** inside the VPC (Service Connect without TLS) | Service tokens and customer data cross the VPC unencrypted. Many teams accept this; regulated workloads usually don't | Service Connect TLS (AWS Private CA) if you ever need encryption in transit end to end |
| d | Autoscaling is **CPU-only** for every service | Queue consumers (inventory, notification, saga) fall behind on backlog without high CPU | Add target tracking on SQS `ApproximateNumberOfMessagesVisible` per task for consumer services |
| e | Spot for dev/staging | A task can get a 2-minute interruption → SIGTERM → `stopTimeout 30` → graceful drain. Messages in flight become visible again (at-least-once handles it) | Fine |
| f | `stopTimeout = 30` vs SQS long poll 20 s + handler time | A consumer mid-batch may be killed. The visibility timeout returns its messages | Fine |

## 2. The `data` module: RDS PostgreSQL + DocumentDB

File: [modules/data/main.tf](ecommerce-infrastructure/terraform/modules/data/main.tf).

| Setting | PostgreSQL | DocumentDB |
|---|---|---|
| Engine | `postgres` **17**, `auto_minor_version_upgrade` | `docdb` **5.0.0** |
| Network | private subnet group, `publicly_accessible = false`, SG from tasks only | same SG |
| TLS | parameter `rds.force_ssl = 1` | parameter `tls = enabled` |
| Encryption at rest | `storage_encrypted` (AWS-managed key) | `storage_encrypted` (AWS-managed key) |
| Credentials | `username = platform_admin`, **`manage_master_user_password = true`** (RDS generates and rotates the secret; never in state) | same |
| HA | `multi_az = var.multi_az` (prod only) | instances count (prod 2 = one replica) |
| Backups | retention 3/7/14 days, window 20:00–21:00 UTC | same |
| Protection | `deletion_protection` + final snapshot when `protect_resources` | same |
| Observability | Performance Insights, `postgresql` log export, `log_min_duration_statement = 1000` ms | `audit_logs` enabled + exported |
| Storage | gp3, 50 GB with autoscaling up to 4× | managed |

**Per-service isolation inside the single instance** is not in Terraform. It's a manual bootstrap step (deployment.md
step 5): run `local/postgres/init.sql` minus the local passwords as `platform_admin` from a one-off task. That step
creates the roles and databases and runs `REVOKE CONNECT … FROM PUBLIC`. It's undocumented in code and easy to get
subtly wrong. Options: codify it as a one-off ECS task image in the infra repo, or use the `cyrilgdn/postgresql`
Terraform provider from inside the VPC.

**TLS verification:** the documented `DATABASE_URL` uses `?sslmode=require`, which **encrypts but does not verify** the
server certificate. `verify-full` with the RDS CA bundle (Order already ships the bundle for DocumentDB) closes the
in-VPC impersonation gap (P3).

**AWS-managed keys** for storage encryption: fine within one account. Snapshots encrypted with the default
`aws/rds` key **cannot be shared cross-account**, which matters if you later want a separate backup or DR account (P3:
a customer-managed key).

### 2.1 Connection budget (finding K-F6, PLAUSIBLE: numbers depend on the instance's exact memory)

| Service | Pool per task (code default) |
|---|---|
| auth (Prisma `PrismaPg` → `pg.Pool` default) | 10 |
| product (SQLAlchemy `pool_size=5, max_overflow=5`) | up to 10 |
| inventory (`DB_POOL_SIZE`) | 10 |
| payment / saga / notification (`createPool(url, max = 10)`) | 10 each |
| **Total for one task each** | **≈ 60** |

RDS PostgreSQL sets `max_connections` from instance memory (`LEAST(DBInstanceClassMemory/9531392, 5000)`). For
`db.t4g.micro` (1 GiB) that's roughly **80–110**; `t4g.small` about double; `m7g.large` several hundred. Now count:
- **dev** (1–2 tasks each): 60 at rest, and **120 during a rolling deploy of everything** (max 200 %) or at max scale. Add migrate
  tasks and the bootstrap session, and dev can run out of connections (`FATAL: remaining connection slots are reserved`).
- **prod** (2–10 tasks): 120 at rest → **600 at max scale** (+ deploy surge). That approaches what an `m7g.large`
  allows, and the alarm threshold is a fixed `300` for every environment.

Fix: set explicit pool sizes per service via env (e.g. 3–5), scale the alarm threshold per class, and consider
**RDS Proxy** if prod autoscaling is real.

## 3. The `messaging` module

File: [modules/messaging/main.tf](ecommerce-infrastructure/terraform/modules/messaging/main.tf). It is the only module
applied anywhere (Floci).

| Resource | Details |
|---|---|
| 5 SNS topics `<env>-ecommerce-{auth,order,inventory,payment,saga}-events` | `kms_master_key_id = var.kms_key_id ?? "alias/aws/sns"` |
| 6 main queues (4 command + 2 inbox) + 6 DLQs | `order-commands.fifo` (and `…-dlq.fifo`); `content_based_deduplication = false`; visibility 60 s; long poll 20 s; retention 4 d (DLQ 14 d); `redrive_policy maxReceiveCount = 5`; SSE-SQS unless a KMS key is passed |
| `aws_sqs_queue_redrive_allow_policy` | only its own main queue may use each DLQ |
| Inbox queue policies | `sqs:SendMessage` for principal `sns.amazonaws.com`, **only** when `aws:SourceArn` is one of the subscribed topics |
| 7 subscriptions | `raw_message_delivery = true`, filter on the `messageType` **message attribute** |
| Per-service IAM documents (`service_access` map) | publish → `sns:Publish` on own topic; send → `sqs:SendMessage`, `GetQueueUrl`; consume → `Receive`, `Delete`, `ChangeMessageVisibility`, `GetQueueAttributes`, `GetQueueUrl`; plus `sns:ListTopics`/`sqs:ListQueues` on `*` as a harmless filler |
| Alarms (`create_alarms`, off locally) | DLQ `ApproximateNumberOfMessagesVisible > 0`; main queue `ApproximateAgeOfOldestMessage > 300 s` for 5 min |

### 3.1 Findings in the messaging module

- **K-F2 (CONFIRMED, code vs IAM): the Notification service can't read DLQs in AWS.**
  [dlq-monitor.ts](ecommerce-notification-service/src/messaging/dlq-monitor.ts) calls `GetQueueUrl`, `GetQueueAttributes`,
  `ReceiveMessage` and `ChangeMessageVisibilityBatch` on the **DLQ** names from `DLQ_NAMES`. The notification IAM
  policy grants consume actions only on the **main** `notification-commands` and `notification-inbox` queues. In AWS
  every DLQ call is `AccessDenied`, so the admin **dead-letters page** and the DLQ monitor fail. Floci **doesn't enforce
  IAM**, which is why no local test could notice. Together with P1-1 (alarms can't publish), **nobody would learn that
  messages are dead-lettering.** Fix: add a `inspect_dlqs` list to `service_access` granting
  `GetQueueUrl`, `GetQueueAttributes`, `ReceiveMessage`, `ChangeMessageVisibility` on the DLQ ARNs (no `DeleteMessage`
  unless redrive from the app is intended).
- **Doc claim not implemented:** messaging-topology.md says "the consumer extends [visibility] for slow work". No
  consumer calls `ChangeMessageVisibility`. The saga handles up to 10 messages **sequentially**, and an event can trigger a
  synchronous Payment call (5 s timeout, plus the provider), so a slow batch can exceed 60 s. The tail of the batch then
  becomes visible to another instance and is processed twice. That's harmless because of the `processed_messages`
  dedupe, but it's wasted work and noisy logs (P3: extend visibility, or receive fewer messages per poll).
- **KMS:** the docs say "KMS CMK in prod", but no environment passes `kms_key_id`, so prod uses AWS-managed keys. That is
  acceptable for SNS→SQS, but it's the same key choice that breaks CloudWatch → the alarm topic (P1-1, platform module).
- **No tests** for this module (only `validate` in CI). It holds the most security-relevant policy documents in
  the repo: queue policies and per-service IAM. A `terraform test` asserting, e.g., "saga may send to exactly four
  queues" and "notification may read its DLQs" would have caught K-F2. Note also that the **service** module's tests
  mock `aws_iam_policy_document` to return an empty statement list
  ([service.tftest.hcl:14-16](ecommerce-infrastructure/terraform/modules/service/tests/service.tftest.hcl#L14-L16)),
  so IAM content isn't asserted there either.

### 3.2 Topology vs code (verified)

Every queue/topic name in `stack/main.tf` env vars comes from module outputs (`local.queue[...]`,
`local.topic[...]`), so names can't drift between Terraform and the services in AWS. The DLQ names in
`DLQ_NAMES` are built by hand (`"${local.name}-notification-commands-dlq,…"`). They match today's naming
scheme, but would silently break if the module's DLQ naming changed. Expose them as a module output instead (P3).
