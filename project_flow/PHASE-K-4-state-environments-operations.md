# Phase K-4: State, Environments, Accounts, the First Apply, and Day-2 Terraform Operations

## 1. State and backends

| Root | Backend | Locking | Notes |
|---|---|---|---|
| `environments/local` | `backend "local" {}` | local file lock | Applied by compose's `messaging-init` with `TF_DATA_DIR=/tmp/terraform-data` (so the container doesn't clobber your `.terraform/`). The state file is git-ignored |
| dev / staging / prod | `backend "s3" {}`, **partial configuration** completed by `terraform init -backend-config=backend.hcl` | `use_lockfile = true` (S3-native lock object, no DynamoDB table) | `backend.hcl` is git-ignored; [backend.hcl.example](ecommerce-infrastructure/terraform/environments/dev/backend.hcl.example) sets `bucket`, `key = ecommerce/<env>/terraform.tfstate`, `region`, `encrypt = true` |

Why a partial backend: the repo contains no account-specific bucket names, and nobody can accidentally `plan`
against a real environment from a fresh clone. Init without `backend.hcl` would just fail.

**Version constraint mismatch (K-F7, CONFIRMED):** every root says `required_version = ">= 1.9"`, but S3-native
locking (`use_lockfile`) arrived in Terraform **1.10** (experimental) and became generally available in **1.11**. Someone
with Terraform 1.9 would get a backend configuration error, or on 1.10 an experimental feature. CI and compose pin
**1.16.2**, so raise the constraint to `>= 1.11` (or pin `~> 1.16`).

**State bucket bootstrapping** is a manual one-time step (deployment.md step 1). The bucket itself isn't in Terraform,
which is a common and acceptable choice (the "chicken and egg" problem), but write the commands down as a script.

## 2. Account strategy (as designed): one account, three environments

Evidence: only dev sets `create_github_oidc_provider = true` ("once per AWS account"). Staging and prod reference the
provider by its constructed ARN.

| Consequence | Why it matters |
|---|---|
| **Destroying dev deletes the account-wide OIDC provider** (K-F5) | dev has `protect_resources = false` and is meant to be torn down. `terraform destroy` in dev removes `aws_iam_openid_connect_provider.github`, and **staging and prod deploys stop working** (their trust policies point at a provider that no longer exists) |
| Human blast radius | An admin session for "dev work" can modify prod resources. IAM scoping per role doesn't help humans |
| Service quotas are shared | e.g. Elastic IPs (5 per region by default: prod's 3 NATs + dev's + staging's = 5, exactly at the default limit), VPCs, Fargate vCPU, CloudFront distributions |
| Naming | all resources prefixed `<env>-ecommerce-…`, so there are no collisions. Good |
| Cost visibility | `default_tags.environment` lets Cost Explorer split by environment. Good |

**Recommended:** an AWS Organization with separate **dev, staging and prod accounts** (plus a shared "tooling" or
"security" account later), and an `environments/account-bootstrap/` root per account for the OIDC provider, the state
bucket and the alarm KMS key. That removes the dev → prod coupling and makes `protect_resources = false` truly safe
for dev. If you stay single-account for cost, at least move the OIDC provider into its own root that is never destroyed.

## 3. The first apply: one-time setup reviewed ([deployment.md](ecommerce-infrastructure/docs/architecture/deployment.md))

| Step | What | Review notes |
|---|---|---|
| 1 | S3 state bucket (versioned, encrypted, public access blocked) → `backend.hcl` | Also enable bucket-level **Object Lock** or at least MFA delete / deny-delete policies for prod state |
| 2 | ACM certs: `shop…` in **us-east-1** (CloudFront), `origin-api.shop…` in the region (ALB) → `terraform.tfvars` | DNS validation must finish before apply (the ALB listener and CloudFront need issued certs) |
| 3 | `terraform plan` → review → **with approval** `terraform apply` | Services start with image tag `bootstrap` (doesn't exist), so 0 healthy tasks and alarms firing until the first CI deploy. Expected |
| 4 | DNS records → CloudFront domain and ALB DNS name | Not in Terraform (no Route 53). With K-F1 in mind: if you adopt VPC origins, `origin-api` DNS isn't needed at all |
| 5 | DB roles: bootstrap SQL as `platform_admin` from a one-off task | **Manual and uncodified** (K-2 §2). Easy to miss `REVOKE CONNECT … FROM PUBLIC` |
| 6 | Fill each `<env>-ecommerce/<svc>` secret; JWT key generation commands; Stripe webhook secret; SES SMTP creds | Good, careful procedure (`shred -u`). SES must be out of the sandbox, or emails reach only verified addresses |
| 7 | GitHub Environments + variables `AWS_DEPLOY_ROLE_ARN`, `AWS_REGION` | The workflows also need `ENV_PREFIX`, `CLUSTER_NAME`, `PRIVATE_SUBNETS`, `TASKS_SECURITY_GROUP` (and `SHOP_ORIGIN`, `SITE_BUCKET`, `DISTRIBUTION_ID` for the frontend). **The doc lists only two of them** (K-F9) |
| 8 | Confirm alarm email subscriptions | Will receive nothing until P1-1 is fixed |

## 4. The safe plan/apply workflow (recommended, not yet in CI)

```bash
cd ecommerce-infrastructure/terraform/environments/dev
terraform init -backend-config=backend.hcl          # once per clone / after backend changes
terraform fmt -check -recursive ../.. && terraform validate
terraform plan -out=tfplan                          # review: look for "must be replaced" (-/+) and "destroy"
terraform show -no-color tfplan > plan.txt          # attach to the PR / change ticket
terraform apply tfplan                              # applies EXACTLY the reviewed plan
```

Reading a plan, from most to least dangerous: `-` destroy, `-/+` replace (forces a new resource: e.g. a queue
becoming FIFO, renaming an RDS identifier, changing a subnet CIDR), `~` update in place, `+` create.
For stateful resources (RDS, DocumentDB, S3, SQS with messages), **any** `-/+` deserves a migration plan.

Later in CI: a PR job with a **read-only** `terraform-plan` role posts the plan; a `main` job in the `production`
Environment (reviewers) applies the saved plan artifact. Never `-auto-approve` for real environments.

## 5. Terraform commands: use, caution, avoid

| Command | Use | Caution / avoid | Why |
|---|---|---|---|
| `terraform init -backend-config=backend.hcl` | first time per env | `-reconfigure` vs `-migrate-state`: know which one you mean when changing backends | `-migrate-state` copies state; `-reconfigure` ignores the old state |
| `terraform init -upgrade` | deliberately moving providers within the constraint | then commit the new `.terraform.lock.hcl` after reviewing it | silent provider upgrades change plans |
| `terraform plan -out=tfplan` / `apply tfplan` | always for real envs | — | what you reviewed is what runs |
| `terraform plan -refresh-only` | detect drift (console changes) without changing anything | — | safe read |
| `terraform apply -auto-approve` | Floci (`messaging-init`), throwaway sandboxes | real accounts | no human checkpoint |
| `-target=…` | emergency surgery | routine use | partial applies leave dependencies stale; the next full plan may surprise you |
| `-replace=ADDRESS` (replaces `taint`) | force recreation of one broken resource | stateful resources | recreation = data loss for DBs/queues |
| `import` blocks / `terraform import` | adopting resources created by hand (e.g. the state bucket, ACM certs) | importing into the wrong address | check `terraform plan` shows no changes after import |
| `moved {}` blocks / `terraform state mv` | refactors (renaming a module key) without recreate | `state rm` (Terraform forgets the resource; it keeps existing **unmanaged**) | prefer `moved` blocks, which are reviewable in code |
| `terraform force-unlock ID` | a crashed run left a lock | when someone else's apply is still running | you can corrupt state |
| `terraform destroy` | dev sandboxes | dev **today** (destroys the shared OIDC provider: K-F5); prod (protected) | irreversible |
| `terraform output -raw role_arns` | copy values into GitHub Environment variables | — | outputs are not secrets here |
| `terraform test` | every change to a module | treating it as proof of AWS behavior | mocked provider |
| `terraform console` | evaluate `cidrsubnet(...)`, locals | — | safe, local |

## 6. Drift and ownership boundaries

| Attribute | Owner | Mechanism | Risk |
|---|---|---|---|
| Task definition contents (image **and env/secrets**) | CI after the first apply | `ignore_changes = [container_definitions]` | Terraform env changes never deploy (P1-4 / J-F4) |
| ECS service `task_definition`, `desired_count` | CI / autoscaler | `ignore_changes` | Correct |
| Secret values | operator CLI | secret containers only | Correct |
| DB roles/databases | bootstrap SQL | outside Terraform | Undocumented drift |
| DNS, ACM | manual | outside Terraform | Acceptable; consider Route 53 + ACM in Terraform later |
| Console edits | nobody | `plan -refresh-only` shows them | Run it on a schedule in CI once AWS exists |

## 7. Cost drivers (qualitative; use the AWS Pricing Calculator or `infracost` for numbers)

Biggest **fixed** costs per environment, from most to least: DocumentDB instances (prod: two `r6g.large`), RDS (prod
Multi-AZ `m7g.large`), **NAT gateways** (hourly + per-GB, ×3 in prod), **interface VPC endpoints** (6 endpoints × AZs, hourly
each: often surprising in dev), the ALB, WAF (per ACL + per rule + per request), Container Insights *enhanced*, and
CloudWatch Logs ingestion. Fargate cost scales with tasks (Spot in dev/staging).

Cheap levers for dev: one AZ worth of endpoints or none (pay NAT data instead), smaller DocumentDB (or run Order on
MongoDB Atlas free tier for dev), Container Insights standard instead of enhanced, scheduled scale-to-zero at
night. Each lever is a trade-off against the "dev mirrors prod" goal. The current design favors fidelity.
