# Phase J-6: Troubleshooting CI/CD Failures, Stage by Stage

**Every error message below is a HYPOTHETICAL example** of what that stage typically prints. None was observed:
no workflow has been run for this analysis. The commands are **recommendations** to run yourself when you choose to.
Nothing here deploys or touches AWS.

General method for any red run:
1. Open the **first** failed step. Later failures are usually consequences.
2. Classify it: *my diff* (lint/types/tests), *environment* (service container, registry, runner image),
   *time-dependent* (new advisory, expired cert), or *flaky* (timing, emulator).
3. Reproduce locally with the **same command and the same inputs** (the lockfile, the same Node/Python major, the same DB major).
4. Fix the cause, never the symptom (no `|| true`, no `continue-on-error`).
5. Verify by re-running locally, then push. Confirm that the exact step went green.

Local prerequisites for DB-backed stages: in the service repo, `docker compose up -d` (starts only its DB). For
messaging tests, also Floci: in `ecommerce-infrastructure`, `docker compose up -d floci`.

---

## Install and audit

### `npm ci`
- **Example:** `npm ERR! code EUSAGE … npm ci can only install packages when your package.json and package-lock.json are in sync. Missing: zod@4.6.8 from lock file`
- **Causes:** `package.json` edited without reinstalling; a lockfile from an npm major with a different format; a merge conflict resolved badly.
- **Reproduce:** `rm -rf node_modules && npm ci`
- **Fix:** `npm install`, review the lockfile diff, commit both files.
- **Auth-specific:** `postinstall: prisma generate` failing points to `prisma/schema.prisma` syntax or `prisma.config.ts`.

### `npm audit --omit=dev --audit-level=high`
- **Example:** `# npm audit report … mysql2 <3.24.5 Severity: high … 4 high severity vulnerabilities` (exit 1)
- **Causes:** a new advisory published since the last green run (common: the diff can be unrelated), or a new dependency.
- **Reproduce:** `npm audit --omit=dev --audit-level=high`; `npm explain mysql2` shows **why** it's installed.
- **Fix, in order of preference:** upgrade the direct dependency; `npm audit fix` (review it, never `--force` blindly, which
  can downgrade majors as with Prisma in S-5); a targeted `overrides` entry (as auth did) with a comment and a test; or, if
  the package is not in the runtime image, document it as accepted (S-5 style).
- **Verify:** audit clean + full test suite + build the runtime image and confirm the package isn't in it
  (`docker run --rm <img> npm ls mysql2`).

### `pip install -r requirements-dev.txt` / `pip-audit`
- **Example:** `ERROR: Could not find a version that satisfies the requirement psycopg-binary==3.3.6` (no wheel for the runner's Python)
  or `Found 1 known vulnerability in 1 package: starlette 0.x GHSA-…`
- **Reproduce:** `python3.14 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt`; `pipx run pip-audit==2.10.0 -r requirements.txt --disable-pip --no-deps`
- **Fix:** bump the pin in **both** requirements files consistently (the README's locking procedure), re-run tests.

## Static checks

### `eslint .` / `ruff check .` / `ruff format --check .`
- **Example:** `src/saga/engine.ts 12:7 error 'x' is assigned a value but never used @typescript-eslint/no-unused-vars` · `app/catalog.py:88:5: S608 Possible SQL injection vector` · `Would reformat: app/routers/products.py`
- **Fix:** `npx eslint . --fix` / `ruff check --fix .` / `ruff format .`. For security rules (`S…`), fix the code; only add `# noqa: S608` with a justification when it's a proven false positive.

### `tsc --noEmit`
- **Example:** `src/clients/order-client.ts(66,7): error TS2345: Argument of type 'string | undefined' is not assignable to parameter of type 'string'.`
- **Causes:** a real type error; a dependency upgrade that changed types (it passes locally with an old `node_modules`).
- **Reproduce:** `npm ci && npm run typecheck` (fresh install = same deps as CI).
- **Frontend special case:** an error inside `src/api/contract-check.ts` (`… { error: "the API no longer provides what the UI reads" … }`) means a re-vendored OpenAPI dropped or changed a field the UI uses. Fix the UI type or pin the previous contracts release.

### Frontend `contracts:types && git diff --exit-code src/api/generated`
- **Example:** `diff --git a/src/api/generated/order-service.ts …` then exit 1
- **Causes:** contracts re-vendored without regenerating; a hand edit of a generated file; a different `openapi-typescript` version.
- **Fix:** `npm run contracts:types`, commit the generated files.

## Database migrations

### Prisma `db:deploy`
- **Example:** `Error: P3018 A migration failed to apply. … Migration name: 20261013161005_email_normalized_check … ERROR: check constraint "…" is violated by some row`
- **Causes:** the SQL is invalid on an empty DB, or (in real environments) existing data violates a new constraint.
- **Reproduce:** `docker compose up -d` (auth DB) → `DATABASE_URL=… npx prisma migrate deploy`.
- **Fix:** a new corrective migration; never edit the applied one. For data-dependent constraints use expand → backfill → constrain (`NOT VALID` then `VALIDATE CONSTRAINT`).

### Prisma `db:check-drift`
- **Example:** exit code **2** with `[+] Added column "lastLoginAt" on table "User"`
- **Meaning:** `schema.prisma` changed with no migration.
- **Fix:** `npx prisma migrate dev --name add_last_login` **locally**, then commit the new folder.
- **Other cause:** `P3014 … could not create the shadow database` means the `CREATE DATABASE auth_shadow` step didn't run, or the role lacks `CREATEDB`.

### TypeORM `migration:run && migration:revert && migration:run` / `db:check-drift`
- **Example:** `QueryFailedError: type "reservation_status" already exists` (a `down()` that forgot `DROP TYPE`), or `Unexpected changes in schema were found in check mode`
- **Fix:** complete the `down()`; for drift: `npx typeorm-ts-node-commonjs migration:generate src/database/migrations/<Name> -d src/database/data-source.ts`, review it, commit.

### node-pg-migrate `db:migrate && db:rollback && db:migrate`
- **Example:** `Error: Not run migration 1791990000000_initial-payment-schema is preceding already run migrations` (ordering/timestamps), or a `-- Down Migration` section that fails
- **Fix:** migration file names must sort after existing ones; make `Down` the exact inverse.

### Alembic round-trip / `alembic check`
- **Example:** `alembic.util.exc.CommandError: Multiple head revisions are present` (two branches each added a migration) · `FAILED: New upgrade operations detected: [('add_column', 'products', …)]`
- **Fix:** `alembic merge -m "merge heads" <rev1> <rev2>`; for check: `alembic revision --autogenerate -m "…"`, review it, commit.

## Tests

### DB or emulator unreachable
- **Example:** `Error: Cannot reach PostgreSQL for integration tests (localhost:5432). Start it with docker compose up -d …` (the message is written in [global-setup.ts](ecommerce-auth-service/tests/global-setup.ts)) · `connect ECONNREFUSED 127.0.0.1:4566`
- **CI cause:** a service container failed its health check (look at "Initialize containers" in the job log); an image tag was pulled from the registry and changed; a port conflict.
- **Local cause:** the DB isn't started, or another Postgres is using 5432.

### Assertion failures
- **Example:** `FAIL tests/saga-flows.test.ts > payment failed → stock released and order cancelled … expected 'CANCELLING' to be 'CANCELLED'`
- **Approach:** run only that test: `npx vitest run tests/saga-flows.test.ts -t "payment failed"` (Jest: `npx jest test/reservations.spec.ts -t "…"`; pytest: `pytest tests/test_products.py -k name -x`). Read the test's arrange/act/assert, then the code path it names.
- **Flaky messaging tests** (pass on retry): usually a timing assumption about SNS→SQS delivery. Fix by polling with a deadline, not a longer `sleep`.

### Generated-artifact tests
- **Example:** `committed openapi/openapi.json is out of date` / `✗ Vendored contracts do not match ecommerce-contracts@v1.2.0 … modified: events/schemas/order-created.v1.schema.json`
- **Fix:** `npm run openapi:export` (Product: `python -m app.export_openapi`) and commit. For contracts: revert the hand edit; change the contract in `ecommerce-contracts`, release it, then `node scripts/vendor.mjs --service <svc> --into ../<repo> --version vX.Y.Z`.

## Docker builds

- **Example:** `ERROR: failed to solve: process "/bin/sh -c npm ci --omit=dev" did not complete successfully: exit code: 1` · `COPY failed: file not found in build context … migrations`
- **Causes:** the lockfile is out of sync (also fails `npm ci` earlier); `.dockerignore` excludes a needed file; a native module build failing under arm64/QEMU (deploy only).
- **Reproduce:** `docker buildx build --target runtime -t test:local .` (and `--target migrate`); arm64: `--platform linux/arm64`.
- **Smoke test (recommended addition):** `docker run --rm -e … test:local` and `curl localhost:<port>/health/live`.

## Contracts

### `npm run compat`
- **Example:** `✗ Breaking change without a major version. Prefer a NEW version of the message (v2 next to v1) …`
- **Fix:** don't bump to major to silence it. Add `<name>.v2.schema.json` next to v1 (minor release), migrate the producers and consumers, and remove v1 later (major). See [breaking-change-demo.md](ecommerce-contracts/docs/breaking-change-demo.md).
- **Shallow-clone cause:** `fatal: No names found, cannot describe anything` locally means the tags aren't fetched (`git fetch --tags`). In CI it means `fetch-depth: 0` was removed.

### `npm run check`
- **Example:** `asyncapi/asyncapi.json is stale`. **Fix:** `npm run build`, commit.

## Terraform

| Stage | Example | Fix |
|---|---|---|
| `fmt -check` | `modules/service/main.tf` listed, exit 3 | `terraform fmt -recursive` in `terraform/` |
| `init -backend=false` | `Error: Failed to query available provider packages … locked provider registry.terraform.io/hashicorp/aws 6.68.0 does not match configured version constraint` | Align `required_providers` with the lock, or `terraform init -upgrade` locally and commit the new `.terraform.lock.hcl` (review it) |
| `validate` | `Error: Reference to undeclared input variable "repo_prefix"` | Declare the variable, or fix the typo |
| `terraform test` | `Error: Test assertion failed … deployment_circuit_breaker …` | A guarantee regressed: restore it, or (if the change is intended) update the assertion **in the same PR** with a reason |
| (future) `plan` against AWS | `NoCredentialProviders` / `AccessDenied: … not authorized to perform: sts:AssumeRoleWithWebIdentity` | OIDC trust `sub` mismatch: check the repo name (`cc-` prefix!) and the environment name |

Reproduce any of these locally: `cd terraform/modules/<m> && terraform init -backend=false && terraform test`. That needs no credentials.

## Workflow and compose linting

- `actionlint`, example: `ci.yml:31:9: property "PRIVATE_SUBNETS" is not defined in object type {...} [expression]` or a shellcheck `SC2086: Double quote to prevent globbing`.
  Reproduce: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color`.
- `docker compose config --quiet`, example: `services.order-service.depends_on.product-service.condition must be one of …`. Reproduce the same command locally.

## Deploy stages (for later, when AWS exists)

| Step | Example | Likely cause | Safe fix |
|---|---|---|---|
| configure-aws-credentials | `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust `sub` mismatch (repo name `cc-…`, environment name `production` vs `prod`), `id-token: write` missing | Fix the trust policy via Terraform (plan, review, apply) |
| ECR push | `tag invalid: The image tag '…' already exists in the '…/auth-service' repository and cannot be overwritten because the repository is immutable` | Re-run of an already-pushed commit (J-F1) | Skip the build when the tag exists: `aws ecr describe-images --repository-name … --image-ids imageTag=$TAG` |
| Migration task | `migration exit code: 1` / `None`; `Waiter TasksStopped failed: Max attempts exceeded` | SQL error / container never started (image pull, secret access) / migration longer than ~10 min | Read logs: `aws logs filter-log-events --log-group-name …` (the role can read its log group); for long migrations, poll `describe-tasks` yourself with a longer budget |
| Rollout | `::error::rollout failed; ECS rolled back to the previous revision` | New tasks fail `/health/ready` (bad config/secret, DB unreachable, crash at boot) | The service already runs the old revision. Fix forward; check `aws ecs describe-services … events` and the task's stopped reason |
| Frontend sync | `AccessDenied … s3:PutObject` | Wrong `SITE_BUCKET` variable for the environment | Fix the Environment variable |
