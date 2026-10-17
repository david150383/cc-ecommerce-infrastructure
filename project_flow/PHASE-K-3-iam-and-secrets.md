# Phase K-3: IAM, Secrets and Encryption: A Least-Privilege Review

## 1. Every identity the design creates (per environment)

| Identity | Count | Trusted by (who can become it) | Permissions | Source |
|---|---|---|---|---|
| Execution role `<env>-ecommerce-<svc>-execution` | 7 | `ecs-tasks.amazonaws.com` | AWS managed `AmazonECSTaskExecutionRolePolicy` (ECR auth + pull, `logs:CreateLogStream/PutLogEvents`, on `*`) + `secretsmanager:GetSecretValue` on **its own** secret | [service/main.tf](ecommerce-infrastructure/terraform/modules/service/main.tf) "IAM" |
| Task role `<env>-ecommerce-<svc>-task` | 7 | `ecs-tasks.amazonaws.com` | messaging policy (below); product: none | service + messaging |
| Deploy role `<env>-ecommerce-deploy-<svc>` | 7 | GitHub OIDC: `aud = sts.amazonaws.com`, `sub = repo:<owner>/ecommerce-<svc>:environment:<env>` | own ECR repo push, `ecs:RegisterTaskDefinition/DescribeTaskDefinition` (`*`), Update/Describe **own** service, `RunTask` own **migrate family** in own cluster, `DescribeTasks` in cluster, `PassRole` own task + execution role to ECS only, read own log group | [github-oidc/main.tf](ecommerce-infrastructure/terraform/modules/github-oidc/main.tf) |
| Deploy role `<env>-ecommerce-deploy-frontend` | 1 | same pattern, `ecommerce-frontend` | `s3:ListBucket` + `Put/Get/DeleteObject` on the site bucket, CloudFront `Create/GetInvalidation` on the distribution | same |
| OIDC provider `token.actions.githubusercontent.com` | 1 per **account** (created by dev) | — | — | github-oidc |
| SNS → SQS (service principal) | per inbox queue | queue policy: `sns.amazonaws.com` + `aws:SourceArn` ∈ subscribed topics | `sqs:SendMessage` on that queue | [messaging/main.tf](ecommerce-infrastructure/terraform/modules/messaging/main.tf) |
| CloudFront → S3 (service principal) | 1 | bucket policy: `cloudfront.amazonaws.com` + `AWS:SourceArn` = the distribution | `s3:GetObject` | [frontend/main.tf](ecommerce-infrastructure/terraform/modules/frontend/main.tf) |
| RDS / DocumentDB master | 2 | RDS-managed Secrets Manager secrets | DB superuser | data module |
| **Humans / Terraform runner** | — | **not defined anywhere** | whoever runs `terraform apply` needs near-admin | — (gap) |

### Messaging task-role matrix (from `service_access`)

| Service | `sns:Publish` | `sqs:SendMessage` (+GetQueueUrl) | consume (Receive/Delete/ChangeVisibility/GetAttributes/GetQueueUrl) |
|---|---|---|---|
| auth | auth-events | — | — |
| order | order-events | notification-commands | order-commands.fifo |
| inventory | inventory-events | — | inventory-commands |
| payment | payment-events | notification-commands | payment-commands |
| saga | saga-events | inventory-, order-, payment-, notification-commands | saga-inbox |
| notification | — | — | notification-commands, notification-inbox (**DLQs missing**: K-F2) |
| product | (no task policy) | — | — |

Cross-check against the code: every SDK call in the services is `Publish`, `SendMessage`, `ReceiveMessage`,
`DeleteMessage` or `GetQueueUrl`, plus the notification DLQ monitor's `GetQueueAttributes` /
`ChangeMessageVisibilityBatch` (found with a grep over all `src/`). Everything is covered except the DLQ calls.

## 2. Blast-radius analysis: "if X is compromised, what can the attacker do?"

| Compromised | Can | Cannot | Containment |
|---|---|---|---|
| **One task** (e.g. RCE in order-service) | Read its own secrets (env), use its DB role, publish its topic, send `NotificationRequested` (spam customers), call other services' `/internal/*` (same SG) with its own service token (audience-limited: Order may only get tokens for Product) | Read other services' secrets; touch other databases (credentials); publish other topics | Good: per-service secret, DB role, task role and token audience |
| **Saga task** | Send **any** command to Inventory, Order, Payment, Notification, including `RefundRequested` | Steal money: refunds go back to the original payment method, and Payment caps them at paid − refunded − pending | The saga is the most privileged messaging identity; an inherent property of orchestration |
| **A service's deploy role** (e.g. a malicious action in payment's deploy job) | Register a task definition with **any image** and the service's own roles, then `UpdateService`. That runs attacker code **with payment's secrets** (Stripe secret key) and DB access | Use another service's roles (PassRole scoped); run tasks of other families (`RunTask` scoped to own migrate family) | Medium: deploy = full control of that service. That's why Environment branch rules + reviewers + SHA-pinned actions matter (Phase J-5) |
| **Frontend deploy role** | Replace the SPA (e.g. inject a card-skimming script into `index.html`) | Touch the backend | CSP `script-src 'self'` limits **third-party** script hosts, but a replaced bundle *is* 'self'. Protect the frontend environment as carefully as payment |
| **Execution role** | Pull **any** image in the account's ECR, write any log group (managed policy uses `*`) | Read other secrets | Standard AWS managed policy; scope it with a custom policy if you want strict per-repo pulls |
| **Dev environment** (same account as prod) | Everything above, within dev's resources | Assume prod roles (different `sub` and role) | Weaker than separate accounts: one compromised **human** admin credential reaches all three environments (K-F5) |

`ecs:RegisterTaskDefinition` has no resource-level permissions (the code comments say so). A deploy role can
register a task definition in **any family name**, but it can't run or deploy it outside its own service, so this is
accepted.

## 3. Secrets: lifecycle and flow

```mermaid
sequenceDiagram
  participant Op as Operator (trusted machine)
  participant SM as Secrets Manager
  participant ECS as ECS agent (execution role)
  participant App as Container
  Op->>SM: put-secret-value <env>-ecommerce/payment-service {"DATABASE_URL":…,"STRIPE_SECRET_KEY":…}
  Note over Op: file shredded afterwards (deployment.md step 6)
  ECS->>SM: GetSecretValue (own secret only) at task START
  ECS->>App: inject each JSON key as an env var (valueFrom arn:KEY::)
  App->>App: Zod validates at boot; never logs values (redaction)
```

| Secret | Keys (from `stack/main.tf` `secrets`) | Who sets it | Rotation path |
|---|---|---|---|
| auth | `DATABASE_URL`, `JWT_SIGNING_KEYS` (JSON array of `{kid, pem}`), `SERVICE_CLIENTS` (SHA-256 hashes) | operator | JWKS supports several `kid`s, so add a new key, deploy, switch signing, remove the old one after the token TTL (runbooks.md) |
| order / payment / saga | `DATABASE_URL` or `MONGODB_URI`, `SERVICE_CLIENT_SECRET` (+ payment: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`) | operator | update the secret → **redeploy** (values are read only at task start) |
| notification | `DATABASE_URL`, `SMTP_USER`, `SMTP_PASSWORD` | operator (SES SMTP credentials) | same |
| product, inventory | `DATABASE_URL` | operator | same |
| DB masters | managed by RDS | RDS | automatic rotation, which **doesn't** affect service roles |

Good properties: no secret value in Terraform code, variables or state (`manage_master_user_password`, empty secret
containers); no secrets in GitHub; each task can read only its own secret.

Gaps:
- Per-service DB role passwords are created by hand (bootstrap SQL) and pasted into secrets. There is no rotation for them.
  Option: RDS **IAM database authentication** (tokens from the task role, no password at all) or Secrets Manager rotation
  Lambdas.
- `aws_secretsmanager_secret` uses the default 30-day recovery window. A destroy + re-apply within 30 days fails with
  "a secret with this name is scheduled for deletion". This matters for dev teardowns (`recovery_window_in_days = 0` for dev).
- Secret changes need a redeploy, which, given J-F1 (rerun fails on an immutable tag), currently means
  `aws ecs update-service --force-new-deployment`, **not** re-running the workflow.

## 4. Encryption summary

| Data | At rest | In transit |
|---|---|---|
| RDS / DocumentDB | encrypted, AWS-managed keys | TLS forced (`rds.force_ssl`, `tls=enabled`); clients `sslmode=require` (no cert verification) |
| SQS / SNS | SSE-SQS / `alias/aws/sns` | HTTPS via VPC endpoints |
| Alarm topic | `alias/aws/sns` → **breaks CloudWatch delivery** (P1-1) | — |
| S3 site bucket | SSE-S3 | CloudFront ↔ S3 SigV4 over HTTPS |
| ECR | AES256 | HTTPS |
| Secrets Manager | `aws/secretsmanager` | HTTPS via endpoint |
| CloudWatch Logs | **not KMS-encrypted** (default service encryption) | HTTPS via endpoint |
| Browser ↔ CloudFront ↔ ALB | — | TLS ≥ 1.2 both hops |
| ALB ↔ tasks, task ↔ task | — | **plain HTTP** inside the VPC |

A customer-managed KMS key strategy (one key per environment and data class) would unlock cross-account
snapshot copies, CloudWatch → SNS alarms, and key-level audit and revocation. It's optional except for the alarm
topic, where it's required (or remove encryption from that topic).

## 5. What a production reviewer would still ask for

1. **Who applies Terraform?** Define a `terraform-apply` role (assumed by humans via SSO, or by a CI job in the
   `production` environment) and a read-only `terraform-plan` role. Today the design is silent on this.
2. **Account-level guardrails** (outside this repo but required): CloudTrail (org trail), GuardDuty, IAM Access Analyzer,
   AWS Config / Security Hub, budgets and alarms, SCPs preventing disabling them.
3. **IAM policy tests**: assert the actual JSON of task, queue and deploy policies (the mocked `aws_iam_policy_document`
   in the service tests hides it). Or run `aws iam simulate-principal-policy` against the real roles after the first
   dev apply: "can notification-task `sqs:ReceiveMessage` on `dev-ecommerce-notification-commands-dlq`?"
4. Per-service security groups so `/internal/*` calls are limited at the network layer too.
