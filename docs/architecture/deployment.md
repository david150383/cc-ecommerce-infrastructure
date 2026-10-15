# Deployment to AWS

Status: **designed, validated and plan-tested offline. Nothing has been applied.** Every module is planned
in CI against a mocked AWS provider (`terraform test`, no credentials). Applying requires explicit approval
(master prompt rule) and the one-time steps below.

## Shape

```
visitor ──HTTPS──▶ CloudFront (shop.example.com)
                     ├─ /*               → S3 (private, origin access control): the SPA
                     └─ /api/*, /.well-known/* → ALB (accepts CloudFront's addresses only)
                                              └─ path rules → ECS Fargate services (private subnets)
                                                   ├─ Service Connect: auth-service:4001, order-service:4004, …
                                                   ├─ RDS PostgreSQL 17 (6 databases)  · DocumentDB (order-service)
                                                   └─ SNS/SQS (messaging module) via VPC endpoints
```

One origin for the shop and its API: no CORS, and the refresh/CSRF cookies are first-party. `/internal/*`,
`/health/*` and `/mock-provider/*` are refused at the ALB.

| Module | Creates |
|---|---|
| `network` | VPC, public/private subnets over 2–3 AZs, NAT (1 shared or 1 per AZ), VPC endpoints (ECR, logs, Secrets Manager, SNS, SQS, S3) |
| `platform` | ECS cluster (Container Insights), Service Connect namespace, ALB (TLS 1.2+, CloudFront-only), ECR (immutable tags, scan on push), alarm topic |
| `data` | RDS PostgreSQL (TLS forced, encrypted, RDS-managed master secret, backups, Multi-AZ in prod), DocumentDB (TLS, encrypted, replica in prod), alarms |
| `service` | Per service: task + migration task definitions (read-only root FS, non-root, secrets from its own Secrets Manager secret), ECS service (circuit-breaker rollback, Service Connect), ALB rules for public paths, CPU autoscaling, IAM (own secret, own queues/topic), logs, alarms |
| `frontend` | Private S3 bucket (versioned), CloudFront with CSP/HSTS headers, SPA routing function |
| `github-oidc` | Deploy role per repository, assumable only from that repository's GitHub environment |
| `messaging` | SNS/SQS topology (Phase 3) |
| `stack` | One environment from all of the above; `environments/{dev,staging,prod}` only set sizes |

| | dev | staging | prod |
|---|---|---|---|
| AZs / NAT | 2 / 1 | 2 / 1 | 3 / 3 |
| Tasks per service | 1–2, Fargate Spot | 1–4, Spot | 2–10, on-demand |
| PostgreSQL | t4g.micro, single-AZ | t4g.small | m7g.large, Multi-AZ |
| DocumentDB instances | 1 | 1 | 2 |
| Backups / deletion protection | 3 days / off | 7 days / on | 14 days / on |

## One-time setup (per AWS account / environment)

1. **State backend**: an S3 bucket (versioned, encrypted, public access blocked) with lockfile-based
   locking; copy `backend.hcl.example` → `backend.hcl`.
2. **Certificates** (ACM): `shop.example.com` in **us-east-1** (CloudFront) and
   `origin-api.shop.example.com` in the deployment region (ALB). Copy `terraform.tfvars.example` →
   `terraform.tfvars` (git-ignored; no secrets in it).
3. `terraform plan` → review → **with approval** `terraform apply`. The services start with the image tag
   `bootstrap`, which does not exist yet: they stay at 0 healthy tasks until the first CI deploy.
4. **DNS**: `shop.example.com` → the CloudFront domain (output `cloudfront_domain`);
   `origin-api.shop.example.com` → the ALB (output `alb_dns_name`).
5. **Database roles**: run the bootstrap SQL (`local/postgres/init.sql` without the local passwords and the
   `CREATEDB` grants) as `platform_admin`, using the RDS-managed master secret, from a one-off task in the
   private subnets. One role + database per service; `REVOKE CONNECT … FROM PUBLIC`. DocumentDB: one
   `order_svc` user with `readWrite` on `order_db`.
6. **Secrets** (values never in Terraform or git). Each service has `<env>-ecommerce/<service>` with the
   keys listed in `modules/stack/main.tf`:
   ```bash
   aws secretsmanager put-secret-value --secret-id prod-ecommerce/payment-service \
     --secret-string file://payment.json        # {"DATABASE_URL": "...?sslmode=require", "STRIPE_SECRET_KEY": "sk_live_...", ...}
   shred -u payment.json
   ```
   - `auth-service.JWT_SIGNING_KEYS`: `[{"kid": "2026-10-15", "pem": "<PKCS#8>"}]` (`npm run key:generate`
     output); `SERVICE_CLIENTS`: the SHA-256 hashes of each client secret.
   - `SERVICE_CLIENT_SECRET` of order/payment/saga: the matching plaintext secrets (generate 32 random bytes).
   - `STRIPE_WEBHOOK_SECRET`: from the Stripe dashboard webhook endpoint
     `https://shop.example.com/api/v1/payments/webhooks/stripe`.
   - Notification `SMTP_USER`/`SMTP_PASSWORD`: SES SMTP credentials (SES domain verified, out of sandbox).
7. **GitHub**: for each repository create the environment (`dev`, `staging`, `production`; production with
   required reviewers) and set `AWS_DEPLOY_ROLE_ARN` (output `deploy_role_arns`) and `AWS_REGION` as
   environment variables (not secrets: they are not sensitive).
8. Confirm the alarm e-mail subscriptions.

## Every deployment (CI, per service repository)

`.github/workflows/deploy.yml` (template in each repo): build the `runtime` and `migrate` images (arm64,
tagged with the git SHA) → push to ECR → run the migration task and wait for exit code 0 → register a task
definition revision with the new image → update the service → wait until stable. If the new tasks fail
their health checks, the ECS circuit breaker rolls back to the previous revision by itself; see
[runbooks.md](runbooks.md) for manual rollback and recovery.

Migrations must be backward compatible with the running version (expand → migrate → contract, as for
contracts): the old tasks keep serving while the new ones start.
