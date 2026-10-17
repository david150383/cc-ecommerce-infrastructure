# Phase A.4: GitHub Actions Workflow Inventory and CI/CD Command Inventory

This is the preliminary inventory. Phase J explains every keyword and command line by line. No workflow run was
observed: `gh` is not installed, and `origin/main` on GitHub currently contains **only `ci.yml`** in each repo.
The deploy workflows below exist only on the local `phase7` branch.

---

## 1. Workflow inventory (21 files)

| Repo | File | Triggers | Jobs | Holds credentials? |
|---|---|---|---|---|
| auth, product, inventory, order, payment, notification, saga, frontend | `ci.yml` | `push: [main]`, `pull_request`, `workflow_call` | `test` → `docker` (`needs: test`) | No. `permissions: contents: read` |
| same 8 repos | `deploy.yml` | `push: [main]`, `workflow_dispatch` | `ci` (calls `ci.yml`) → `dev` → `staging` → `production` (each calls `deploy-environment.yml`) | Only through OIDC in the called jobs |
| same 8 repos | `deploy-environment.yml` | `workflow_call(environment)` | `deploy` in GitHub environment `${{ inputs.environment }}` | `id-token: write` → `aws-actions/configure-aws-credentials@v4` (OIDC role, no stored keys) |
| contracts | `ci.yml` | `push: [main]`, tags `v*`, `pull_request` | `contracts` | No |
| infrastructure | `ci.yml` | `push: [main]`, `pull_request` | `terraform` (matrix of 5 roots), `terraform-tests` (matrix of 8 modules), `workflows` (actionlint), `compose` | No (mocked provider) |
| infrastructure | `e2e.yml` | `schedule: "30 21 * * *"` (03:00 IST), `workflow_dispatch` | `platform` (60 min timeout) | No |

`deploy.yml` / `deploy-environment.yml` are **generated** from
[ecommerce-infrastructure/templates](ecommerce-infrastructure/templates) by
[scripts/generate-workflows.py](ecommerce-infrastructure/scripts/generate-workflows.py). They are identical
except for the service name (verified with `diff`). The frontend's variant builds and syncs to S3 instead of ECS.

### Shared keywords present

| Keyword | Value used | Effect |
|---|---|---|
| `permissions` | `contents: read` (CI); `+ id-token: write` (deploy) | Least privilege for `GITHUB_TOKEN`; `id-token` lets the job request an OIDC JWT for AWS |
| `concurrency` (CI) | `group: ci-${{ github.ref }}`, `cancel-in-progress: true` | A new push to a PR cancels the older run |
| `concurrency` (deploy) | workflow `deploy-<svc>`, job `deploy-<svc>-<env>`, `cancel-in-progress: false` | Deploys queue and are never killed halfway |
| `services:` | postgres:17-alpine / mongo:8 / floci/floci:2.0.1 with `--health-cmd` | Real dependencies for integration tests; the job waits until they are healthy |
| `environment:` | `dev` / `staging` / `production` | GitHub Environment: its variables, and (if configured on GitHub) required reviewers. **Reviewer configuration is not visible from the repo** |
| `strategy.matrix` | infra only | Parallel validation per Terraform root/module |
| caching | `setup-node cache: npm`, `setup-python cache: pip`, frontend `cache-from/to: type=gha` | Faster installs; backend Docker builds have **no** layer cache in CI |
| artifacts | none uploaded | Images are built with `--load` in CI and discarded |

---

## 2. Pipeline shape per repository type

### Node backend (`ci.yml` in auth / inventory / order / payment / saga / notification)

```
checkout → setup-node (.nvmrc, npm cache) → npm ci → npm audit --omit=dev --audit-level=high
→ npm run lint → npm run typecheck → [migration check] → npm test (against real Postgres/Mongo + Floci)
→ npm run build    ║  then job `docker`: buildx build --target runtime / --target migrate --load
```

Migration checks differ per tool (this is the most service-specific part):

| Repo | Migration step(s) in CI |
|---|---|
| auth | `npm run db:deploy` (`prisma migrate deploy` on an empty DB), then create `auth_shadow` + `npm run db:check-drift` (`prisma migrate diff --from-migrations … --to-schema … --exit-code`) |
| inventory | `migration:run && migration:revert && migration:run` (round-trip), `db:check-drift` |
| payment, saga, notification | `db:migrate && db:rollback && db:migrate` (node-pg-migrate round-trip) |
| order | none (MongoDB; indexes come from `sync-indexes`) |

### Product (Python)

```
checkout → setup-python (.python-version, pip cache) → pip install -r requirements-dev.txt && pip install --no-deps -e .
→ pipx run pip-audit==2.10.0 -r requirements.txt → ruff check . → ruff format --check .
→ alembic upgrade head && alembic downgrade base && alembic upgrade head → alembic check → pytest
║ docker job as above
```

### Frontend

```
checkout → setup-node → npm ci → npm audit → npm run lint
→ npm run contracts:types && git diff --exit-code src/api/generated   (types regenerated from pinned OpenAPI must match)
→ npm run typecheck (includes the compile-time contract check src/api/contract-check.ts) → npm test → npm run build
║ docker/build-push-action@v6 push:false with GHA layer cache
```

### Contracts

```
checkout (fetch-depth: 0, needs tags) → npm ci → npm audit → npm run lint → npm test → npm run check (generated files current)
→ npm run compat (diff vs the latest release tag; fails if the version bump is too small)
```

### Infrastructure

```
terraform job ×5 roots: fmt -check -recursive → init -backend=false -input=false → validate
terraform-tests ×8 modules: init -backend=false → terraform test (mocked AWS provider)
workflows: docker://rhysd/actionlint:1.7.7
compose: docker compose --profile apps config --quiet
```

### Deploy (`deploy-environment.yml`, per environment)

```
checkout → configure-aws-credentials (OIDC role from vars.AWS_DEPLOY_ROLE_ARN) → amazon-ecr-login
→ setup-qemu + setup-buildx → buildx --platform linux/arm64 --target runtime/migrate --push (tag = git SHA)
→ register migrate task def with new image → ecs run-task → wait tasks-stopped → require exitCode 0
→ register service task def → ecs update-service → poll rolloutState (COMPLETED / FAILED, 15 min max)
```

---

## 3. Preliminary CI/CD command inventory

| Command | Where | Reads | Changes | Network / creds | Safe on PRs? |
|---|---|---|---|---|---|
| `npm ci` | all Node CI, frontend deploy | `package-lock.json` (must match `package.json`) | deletes and recreates `node_modules` | npm registry | Yes |
| `npm audit --omit=dev --audit-level=high` | all Node CI | lockfile + advisory DB | nothing | npm registry | Yes; fails on new high/critical prod advisories |
| `npm run lint` / `typecheck` / `build` | all Node CI | sources | `dist/` | none | Yes |
| `prisma migrate deploy` | auth CI, auth migrate image | `prisma/migrations` | applies pending migrations | DB | Yes (throwaway DB in CI) |
| `prisma migrate diff … --exit-code` | auth CI | migrations + `schema.prisma` + shadow DB | nothing | DB | Yes |
| `typeorm migration:run / revert` | inventory CI | `src/database/migrations` | schema | DB | Yes |
| `node-pg-migrate up / down` | payment, saga, notification | `migrations/*.sql` | schema | DB | Yes |
| `alembic upgrade head / downgrade base / check` | product CI | `alembic/versions`, models | schema | DB | Yes |
| `pip install -r requirements-dev.txt` | product CI | pinned requirements | venv | PyPI | Yes |
| `pipx run pip-audit==2.10.0 -r requirements.txt --no-deps` | product CI | requirements | nothing | PyPI + vuln DB | Yes |
| `ruff check .` / `ruff format --check .` | product CI | sources | nothing | none | Yes |
| `pytest` | product CI | tests | test DB | DB | Yes |
| `npm test` (Vitest / Jest) | Node CI | tests | test DBs, Floci queues (prefixed, cleaned up) | DB + Floci | Yes |
| `docker buildx build --target X --load .` | CI docker job | Dockerfile, context | local image | registry pulls | Yes (no push) |
| `docker buildx build --platform linux/arm64 … --push` | deploy | same | **pushes to ECR** | AWS (OIDC) | **No**: main/dispatch only |
| `aws ecs register-task-definition / run-task / update-service` | deploy | live task def | **production changes** | AWS | **No** |
| `aws s3 sync … / aws cloudfront create-invalidation` | frontend deploy | `dist/` | site bucket, CDN cache | AWS | **No** |
| `terraform fmt -check -recursive` | infra CI | `.tf` files | nothing | none | Yes |
| `terraform init -backend=false -input=false` | infra CI | modules, `.terraform.lock.hcl` | `.terraform/` | provider registry | Yes; no state access |
| `terraform validate` | infra CI | config | nothing | none | Yes |
| `terraform test` | infra CI | `tests/*.tftest.hcl` | nothing real (mocked provider) | registry only | Yes |
| `terraform apply -auto-approve` | **compose `messaging-init` only** (Floci) | local env | Floci topology | local emulator | n/a: local; never against AWS |
| `actionlint` | infra CI | workflows | nothing | none | Yes |
| `docker compose --profile apps config --quiet` | infra CI | compose.yaml | nothing | none | Yes |
| `npm run contracts:types && git diff --exit-code src/api/generated` | frontend CI | pinned OpenAPI | regenerates types | none | Yes |
| `npm run compat` | contracts CI | latest tag vs working tree | nothing | none (needs `fetch-depth: 0`) | Yes |
| `npx playwright install --with-deps --only-shell chromium` / `npm run e2e` | infra `e2e.yml` | — | browsers | internet | n/a (nightly) |

**Not present anywhere (by design or gap):** `terraform plan` or `apply` against AWS in CI (correct for now),
container image scanning in CI (ECR scan-on-push is designed), SBOM/provenance attestations, action pinning by
SHA (all actions use tags such as `@v4`), and Dependabot/Renovate (finding S-8 is open).

---

## 4. Ordering: what is good and what to question

**Good:**
- Cheap checks run first (audit, lint, typecheck), then slow ones (DB-backed tests). The Docker job `needs: test`,
  so images are built only from code that passed.
- Migrations are tested **before** the tests use the schema, and three tools round-trip down/up, which proves the
  `down` migrations work.
- Drift checks (`prisma migrate diff`, `typeorm` drift, `alembic check`) catch "changed the model, forgot the
  migration".
- Deploy: migrations run first and must exit 0 before the rollout. The ECS circuit breaker rolls back unhealthy
  revisions. Production depends on staging, which depends on dev.
- No job that runs PR code has AWS credentials. `pull_request` (not `pull_request_target`) means fork PRs get no
  secrets.

**Question (details and fixes in the risks file):**
1. **The image is rebuilt in every environment** ([deploy-environment.yml:45-52](ecommerce-auth-service/.github/workflows/deploy-environment.yml#L45-L52)).
   Production runs an image that was built separately from the one staging tested. With unpinned base tags
   (`node:24-alpine`), the bytes can differ. The usual rule is *build once, promote the same digest*.
2. **CI concurrency collision on `main`** (PLAUSIBLE): a push to `main` starts `ci.yml` (push trigger) **and**
   `deploy.yml → ci.yml` (workflow_call). In a called workflow `github.ref` is the caller's, so both use group
   `ci-refs/heads/main` with `cancel-in-progress: true`, and one can cancel the other. If the deploy's CI is the
   one cancelled, the deploy is cancelled too.
3. **Once `phase7` is merged and pushed, every push to `main` starts `deploy.yml`.** AWS is not set up
   (`vars.AWS_DEPLOY_ROLE_ARN` empty), so the `dev` job will fail on every push, and `main` will show red.
4. `if: true` on the migration step ([deploy-environment.yml:55](ecommerce-auth-service/.github/workflows/deploy-environment.yml#L55))
   is a template leftover (the frontend variant removes the step). It is harmless but noisy.
5. Repository names: the OIDC trust policy and `e2e.yml` expect `ecommerce-<name>`, but the GitHub remotes are
   `cc-ecommerce-<name>`. Both would fail as written.
6. Infra `terraform fmt -check -recursive` runs 5× (once per matrix entry) over the same tree. Harmless
   duplication.

## 5. Independent pipelines (preview of Phase J §G)

| Check | Every service | Language-specific | Frontend only | Infra only | Contracts only |
|---|---|---|---|---|---|
| Locked install, dependency audit, lint, typecheck/format | ✓ | npm vs pip-audit/ruff | | | |
| Migrations apply + round-trip + drift | ✓ (DB owners) | Prisma / TypeORM / node-pg-migrate / Alembic | | | |
| Integration tests against real DB + Floci | ✓ | | | | |
| Vendored contract files unmodified (`contracts:verify`, lockfile SHA-256) | ✓ (as a test) | | ✓ | | |
| Generated API types equal pinned OpenAPI | | | ✓ | | |
| Compatibility vs last release + version bump | | | | | ✓ |
| fmt / validate / mocked plan tests / actionlint / compose config | | | | ✓ | |
| Whole-platform E2E | nightly in infra, not per-PR | | | ✓ | |

Each service pins its **own** contracts release, so producers and consumers upgrade independently. Current pins:
auth v1.0.0, payment v1.0.0, notification v1.0.0, inventory v1.2.0, order v1.2.0, saga v1.2.0, frontend v1.3.0.
Different pins are expected under this design. The compat check makes old pins safe as long as only additive changes
were released.
