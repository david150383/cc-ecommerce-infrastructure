# Phase J-3: The Deploy Pipeline (`deploy.yml` + `deploy-environment.yml`)

Status: exists only on the local `phase7` branches. It has **never run**, and the AWS side has never been applied.
You have chosen not to deploy, which is correct: nothing on the AWS side exists yet.

Sources: [ecommerce-auth-service/.github/workflows/deploy.yml](ecommerce-auth-service/.github/workflows/deploy.yml),
[deploy-environment.yml](ecommerce-auth-service/.github/workflows/deploy-environment.yml), the frontend variant
[ecommerce-frontend/.github/workflows/deploy-environment.yml](ecommerce-frontend/.github/workflows/deploy-environment.yml),
and the generator [generate-workflows.py](ecommerce-infrastructure/scripts/generate-workflows.py).

---

## 1. `deploy.yml`: the promotion chain

```yaml
name: deploy
on:
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: deploy-auth-service
  cancel-in-progress: false
jobs:
  ci:         { uses: ./.github/workflows/ci.yml }
  dev:        { needs: ci,      uses: ./.github/workflows/deploy-environment.yml, with: { environment: dev },        permissions: { contents: read, id-token: write } }
  staging:    { needs: dev,     uses: …, with: { environment: staging },    permissions: … }
  production: { needs: staging, uses: …, with: { environment: production }, permissions: … }
```

| Element | Explanation |
|---|---|
| `push: [main]` | **Continuous deployment**: every merge to `main` starts a deploy. This is why merging `phase7` today would produce a failing run on every push (the `dev` job can't assume a role that doesn't exist) |
| `workflow_dispatch` | Manual run. GitHub lets the user pick **any branch**, and only GitHub Environment branch rules stop a feature branch from reaching production (J-5) |
| workflow `concurrency: deploy-<svc>`, no cancel | Two pushes in a row: the second run **waits** (and only the newest pending run is kept). Deploys are never interrupted |
| `ci` job | Re-runs the full CI as a gate. Deploy can't bypass tests even when triggered manually |
| `dev → staging → production` via `needs` | Sequential promotion: production deploys only if staging's job succeeded, staging only if dev's did |
| per-job `permissions: id-token: write` | Only the deploy jobs can mint OIDC tokens. The `ci` job has no `permissions:` key, so it gets the token defaults, narrowed by `ci.yml`'s own top-level `contents: read`. Adding a top-level `permissions: contents: read` to `deploy.yml` would make that explicit (hardening) |
| Approval for production | **Not in YAML.** It comes from the `production` GitHub Environment's *required reviewers*. The job pauses until someone approves. If that setting isn't configured on GitHub, production deploys automatically right after staging |

## 2. `deploy-environment.yml` (backend): line by line

```yaml
on:
  workflow_call:
    inputs:
      environment: { type: string, required: true }
permissions:
  contents: read
  id-token: write # OIDC: no AWS keys are stored anywhere
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    concurrency:
      group: deploy-auth-service-${{ inputs.environment }}
      cancel-in-progress: false # never interrupt a deployment halfway
    env:
      SERVICE: auth-service
      FAMILY: ${{ vars.ENV_PREFIX }}-auth-service
      CLUSTER: ${{ vars.CLUSTER_NAME }}
      TAG: ${{ github.sha }}
```

- **`environment:`** binds the job to a GitHub Environment. Three effects: (1) `vars.*` resolve from that environment
  (`AWS_DEPLOY_ROLE_ARN`, `AWS_REGION`, `ENV_PREFIX`, `CLUSTER_NAME`, `PRIVATE_SUBNETS`, `TASKS_SECURITY_GROUP`);
  (2) protection rules apply (reviewers, wait timer, allowed branches); (3) the OIDC token's `sub` claim
  becomes `repo:<owner>/<repo>:environment:<env>`, which is exactly what the AWS role trust policy requires
  ([github-oidc/main.tf:83-93](ecommerce-infrastructure/terraform/modules/github-oidc/main.tf#L83-L93)).
- **Job-level concurrency per environment** prevents two deploys to the same environment at once (e.g. a manual run
  racing a push).
- **`TAG: github.sha`**: the image tag is the commit, so you can trace every running container back to source.

### Step 1: `actions/checkout@v4`
Needed for the Dockerfile and build context.

### Step 2: `aws-actions/configure-aws-credentials@v4` with `role-to-assume`, `aws-region`
- Requests a GitHub OIDC JWT (audience `sts.amazonaws.com`) and calls **`sts:AssumeRoleWithWebIdentity`**. It exports
  short-lived credentials (1 h default) as env vars for later steps.
- AWS checks the token's issuer (`token.actions.githubusercontent.com`), `aud`, and `sub` against the trust policy.
- **Why no keys:** nothing long-lived to leak or rotate. A token from a fork, another repo, or a job without the
  environment has a different `sub` and is refused.
- Today this step would fail: `vars.AWS_DEPLOY_ROLE_ARN` is unset (no environments configured), **and** the trust
  policy expects repo `ecommerce-auth-service`, not `cc-ecommerce-auth-service`.

### Step 3: `aws-actions/amazon-ecr-login@v2` (`id: ecr`)
Runs `docker login` against the account's ECR registry and outputs `registry` (`<acct>.dkr.ecr.<region>.amazonaws.com`).

### Step 4: `docker/setup-qemu-action@v3` + `docker/setup-buildx-action@v3`
QEMU lets the x86 runner **emulate arm64**, because the tasks run on Graviton (`linux/arm64`, cheaper per vCPU).
Emulated builds are several times slower, and native-dependency builds (argon2, psycopg) are the slowest part.
Alternative: GitHub's arm64 runners (`runs-on: ubuntu-24.04-arm`) build natively.

### Step 5: Build and push
```bash
set -euo pipefail
docker buildx build --platform linux/arm64 --target runtime -t "$REPO:$TAG" --push .
docker buildx build --platform linux/arm64 --target migrate -t "$REPO:$TAG-migrate" --push .
echo "IMAGE=$REPO:$TAG" >> "$GITHUB_ENV"
```
- `REPO = <registry>/<ENV_PREFIX>/auth-service`: **one ECR repository per environment**. The image is
  rebuilt and pushed separately for dev, staging and production (finding P1-5).
- `set -euo pipefail`: exit on any error (`-e`), on unset variables (`-u`), and when any command in a pipe fails.
  Every multi-line deploy script should start like this.
- `--push` sends layers and the manifest to ECR. The registry is **`IMMUTABLE`**
  ([platform/main.tf:183](ecommerce-infrastructure/terraform/modules/platform/main.tf#L183)), so a tag can never
  be overwritten.
- ⚠ **Consequence (CONFIRMED config + ECR semantics):** re-running this job for a commit that was already pushed to
  this environment fails right here, because the tag already exists. That breaks two things the docs rely on:
  - [runbooks.md](ecommerce-infrastructure/docs/architecture/runbooks.md) §Rollback: "re-run the deploy workflow for
    the previous commit". That commit's tag already exists in that environment's ECR, so the rerun fails at push.
  - "Re-run failed jobs" after a failure **later** in the job (e.g. the migration task failed transiently). The rerun
    fails at push before reaching the migration. Finding **J-F1** (J-7) has the fix (skip the build when the tag exists).
- `GITHUB_ENV`: exports `IMAGE` to later steps.

### Step 6: Run database migrations (one-off task; must exit 0)
```bash
td=$(aws ecs describe-task-definition --task-definition "$FAMILY-migrate" --query taskDefinition)
new=$(echo "$td" | jq --arg img "$IMAGE-migrate" '.containerDefinitions[0].image = $img
  | {family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions, volumes, requiresCompatibilities, cpu, memory, runtimePlatform}')
arn=$(aws ecs register-task-definition --cli-input-json "$new" --query taskDefinition.taskDefinitionArn --output text)
task=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$arn" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[…],securityGroups=[…],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task"
code=$(aws ecs describe-tasks … --query 'tasks[0].containers[0].exitCode' --output text)
test "$code" = "0"
```
| Line | Meaning |
|---|---|
| `describe-task-definition` | Fetches the **latest revision** of the migrate family (created by Terraform at first, then by CI) |
| `jq … .image = $img \| {…}` | Swaps the image and keeps only the fields `register-task-definition` accepts (the describe output has read-only fields such as `revision`, `status`, `registeredAt`). Side effect: fields **not** in that list (e.g. `ephemeralStorage`, `tags`, `pidMode`) are silently dropped if Terraform ever sets them |
| `register-task-definition` | New revision = old config + new image. This is why Terraform env changes never arrive (finding P1-4) |
| `run-task … assignPublicIp=DISABLED` | One Fargate task in the private subnets, with the tasks security group. It reaches RDS and Secrets Manager via VPC endpoints |
| `aws ecs wait tasks-stopped` | Polls until the task stops. The AWS CLI waiter gives up after about **10 minutes** (100 × 6 s), so a longer migration fails this step even if it later succeeds |
| `exitCode` check | `0` = success. If the container never started (image pull or secret fetch error), `exitCode` is missing (`None`), and `test` correctly fails |
| `if: true` | Template placeholder `__HAS_MIGRATIONS__` (always `true`). The frontend template has no migration step at all |

**Why migrations go before the rollout:** new code may need the new schema. The old tasks keep running during
the migration and rollout, so every migration must be **backward compatible** with the running version
(expand → migrate → contract). Migrations run three times (dev, staging, prod), each against that environment's DB.

### Step 7: Deploy the new revision and wait
```bash
… register-task-definition (same jq swap, family $FAMILY) …
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$arn"
for _ in $(seq 1 60); do
  state=$(aws ecs describe-services … --query "services[0].deployments[?taskDefinition=='$arn'].rolloutState | [0]" --output text)
  case "$state" in COMPLETED) exit 0 ;; FAILED) echo "::error::rollout failed; ECS rolled back…"; exit 1 ;; esac
  sleep 15
done
echo "::error::rollout did not finish in 15 minutes"; exit 1
```
- `update-service` starts a rolling deployment: start new tasks → wait for ALB `/health/ready` → drain old tasks
  (`minimum_healthy_percent = 100`, so capacity never drops).
- The ECS **deployment circuit breaker** with `rollback = true`
  ([service/main.tf:378](ecommerce-infrastructure/terraform/modules/service/main.tf#L378)) marks the deployment
  `FAILED` after repeated task failures and redeploys the previous revision. The job then exits 1, so a rollback
  shows as a red workflow.
- `::error::` is a workflow command that creates an annotation in the run summary.
- Nuance (PLAUSIBLE): after a rollback completes, ECS may drop the failed deployment from `deployments[]`. The query then
  returns `None` and the loop runs out at 15 minutes instead of exiting immediately. It's still red, just slower and
  with a less precise message.

## 3. Frontend variant

[ecommerce-frontend/.github/workflows/deploy-environment.yml](ecommerce-frontend/.github/workflows/deploy-environment.yml)

```
checkout → setup-node → npm ci → npm run build (all VITE_*_API_URL = vars.SHOP_ORIGIN)
→ configure-aws-credentials (OIDC) →
  aws s3 sync dist/assets s3://$BUCKET/assets --cache-control "public, max-age=31536000, immutable"
  aws s3 sync dist s3://$BUCKET --exclude "assets/*" --exclude index.html --cache-control "public, max-age=300"
  aws s3 cp dist/index.html s3://$BUCKET/index.html --cache-control "no-cache"
  aws cloudfront create-invalidation --distribution-id $DISTRIBUTION --paths /index.html
```

| Decision | Reason |
|---|---|
| Assets first, `index.html` last | A browser that loads the new `index.html` must find the new hashed assets already uploaded. The reverse order would give users a broken page for a few seconds |
| `immutable`, 1-year cache for `assets/` | File names contain a content hash (Vite), so a changed file gets a new name |
| `no-cache` on `index.html` + invalidate only `/index.html` | The entry point is always revalidated, and one cheap invalidation is enough |
| No `--delete` on sync | Old hashed assets stay, so users with an old tab open don't get 404s on lazy-loaded chunks. The bucket grows (the versioned bucket plus a lifecycle rule handles that) |
| Builds per environment | Required here because `VITE_*` are build-time values. But since production uses **one origin**, every `VITE_*_API_URL` is the same shop origin. With relative URLs (`""`), one build could be promoted everywhere |
| No ECR, no migrations | Static site |

## 4. The generator

[generate-workflows.py](ecommerce-infrastructure/scripts/generate-workflows.py) renders the templates for 7 services +
frontend (`__SERVICE__` → name, `__HAS_MIGRATIONS__` → `true`), writes them into the sibling repos, and makes sure
each `ci.yml` has `workflow_call:`. Its docstring says to run `--check` "in CI", but **no CI runs it**. It can't in
the current layout, because each repo's CI checks out only that repo. Template drift (someone edits a generated file in a
service repo) is therefore detected only when someone regenerates by hand. Options: run `--check` in the nightly
`e2e.yml` (it already clones everything), or move the deploy logic into **one reusable workflow** in a central
repo that each service calls with `uses: <owner>/cc-ecommerce-infrastructure/.github/workflows/deploy-service.yml@<sha>`.
That leaves nothing to generate.

## 5. If you merged `phase7` and pushed today (do not)

1. `ci.yml` runs twice (push + called by deploy); they may cancel each other (J-F2).
2. `deploy / dev` reaches `configure-aws-credentials` and fails: no role ARN variable, no role, wrong repo name in the
   trust policy. Staging and production are skipped.
3. Nothing is created or changed anywhere. Failure is safe, just red on every push.

Before ever enabling it: configure Environments and branch rules, apply the infrastructure with approval, fix P1-1,
P1-3 (repo prefix variable), P1-4, P1-5/J-F1. Section 6 of J-7 lists the order.
