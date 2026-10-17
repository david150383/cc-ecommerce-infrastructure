# Phase J-1: `ci.yml` of the Six Node.js Backends, Line by Line

Reference file: [ecommerce-auth-service/.github/workflows/ci.yml](ecommerce-auth-service/.github/workflows/ci.yml)
(72 lines). Inventory, order, payment, saga and notification follow the same skeleton. Their differences are in §4.

---

## 1. Header (lines 1–14)

```yaml
name: CI
on:
  workflow_call:          # inserted by generate-workflows.py so deploy.yml can call this file
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

| Line | Why it is there | What would happen without it |
|---|---|---|
| `workflow_call` | `deploy.yml` reuses this exact pipeline as its first job, so the deploy can't skip CI | Deploy would need a duplicate copy of CI, which drifts |
| `push: [main]` | Validates what actually landed on `main` (after merges) | Main could be broken by a merge of two individually green PRs |
| `pull_request` | Validates PRs before merge. It runs on the **merge result**, with no secrets for forks | No pre-merge feedback |
| `permissions: contents: read` | `GITHUB_TOKEN` can only read the repo | The token would get the repo/org default, which may be write. A compromised dependency's install script could then push code |
| `concurrency` | Pushing again to a PR cancels the outdated run, which saves minutes | Every push runs to completion |

⚠ `group: ci-${{ github.ref }}` collides on `main` between this run and the copy called by `deploy.yml`.
Details and fix: J-7 finding **J-F2**.

## 2. Job `test` (lines 16–61)

### 2.1 Runner and service containers

```yaml
runs-on: ubuntu-latest
services:
  postgres:
    image: postgres:17-alpine
    env: { POSTGRES_USER: auth_svc, POSTGRES_PASSWORD: auth_local_pw, POSTGRES_DB: auth_db }
    ports: ["5432:5432"]
    options: >-
      --health-cmd "pg_isready -U auth_svc -d auth_db"
      --health-interval 5s --health-timeout 3s --health-retries 20
  floci:
    image: floci/floci:2.0.1
    ports: ["4566:4566"]
    options: >-
      --health-cmd "curl -fs http://localhost:4566/_floci/health" ...
```

- **What:** GitHub starts these containers before the first step and waits until each health check passes (up to
  20 × 5 s = 100 s for Postgres).
- **Why a real Postgres and a real emulator:** the riskiest code here is SQL (locks, constraints, `SKIP LOCKED`)
  and messaging (delete-after-success, DLQ). Mocks would test your assumptions about Postgres and SQS, not
  Postgres and SQS.
- **`POSTGRES_USER: auth_svc`**: the service role is the superuser of this throwaway DB. It can therefore
  `CREATE DATABASE` (needed for `auth_test` and `auth_shadow`). In production `auth_svc` cannot.
- **Passwords in plain YAML** are fine: the DB dies with the job and is reachable only from the runner. Never put
  a real credential here.
- **`floci/floci:2.0.1`** is pinned by tag. A new emulator version can't silently change test behavior.
- **Alternative:** Testcontainers, where the tests start their own containers. It is portable to laptops, but slower
  and needs Docker in the test process. The project instead documents `docker compose up -d` for local runs.

### 2.2 Job env (lines 37–41)

```yaml
DATABASE_URL:        postgresql://auth_svc:auth_local_pw@localhost:5432/auth_db
SHADOW_DATABASE_URL: postgresql://auth_svc:auth_local_pw@localhost:5432/auth_shadow
TEST_DATABASE_URL:   postgresql://auth_svc:auth_local_pw@localhost:5432/auth_test
TEST_AWS_ENDPOINT_URL: http://localhost:4566
```

There are three databases on one server, each with a purpose: `auth_db` (migration smoke test), `auth_shadow` (Prisma's
scratch DB for drift detection) and `auth_test` (recreated by the test suite). `localhost` works because steps run
on the VM, and the service containers publish their ports there.

### 2.3 Steps, one by one

#### `uses: actions/checkout@v4`
- **Does:** clones the repo at the triggering commit (`github.sha`). For PRs that is the merge commit. Defaults:
  `fetch-depth: 1` (no history, no tags) and `persist-credentials: true` (the token is written into `.git/config`
  so later `git` commands can authenticate).
- **Why first:** every later step needs the files.
- **Caution:** `persist-credentials: true` leaves a usable token on disk for every later step, including
  `npm ci` install scripts. Here it's read-only, but `persist-credentials: false` is a cheap hardening.

#### `uses: actions/setup-node@v4` with `node-version-file: .nvmrc`, `cache: npm`
- **Does:** installs Node matching `.nvmrc` = `24`, meaning the **newest 24.x**, not an exact patch. `cache: npm`
  restores and saves `~/.npm` (the download cache, **not** `node_modules`), keyed by a hash of `package-lock.json`.
- **Why:** the same major as the Docker image (`node:24-alpine`) and as your laptop (`nvm use`).
- **Nuance:** the patch version can differ between CI, Docker and laptop. For byte-for-byte reproducibility,
  pin `24.x.y` in `.nvmrc` and the image digest.

#### `run: npm ci`  (comment: postinstall runs `prisma generate`)
- **Purpose:** a clean, exact install from `package-lock.json`.
- **Internals:** deletes `node_modules`, installs exactly the locked versions, verifies integrity hashes, and
  **fails** if `package.json` and the lockfile disagree. It never rewrites the lockfile. Then it runs lifecycle scripts,
  here `postinstall: prisma generate`, which writes the typed client into `src/generated/prisma`.
- **Network:** npm registry. **Safe for PRs:** yes, with no secrets present.
- **vs `npm install`:** `install` may update the lockfile and resolve newer versions within ranges (`^7.10.0`). CI
  would then test code no one committed. Use `npm install <pkg>` locally when **changing** dependencies, and commit the
  lockfile.
- **Caution:** install scripts of every dependency run with the job's token and network. `npm ci --ignore-scripts`
  (as the auth **runtime** Dockerfile does) is stricter, but would skip `prisma generate`, so it would need an
  explicit step.

#### `run: npm audit --omit=dev --audit-level=high`
- **Purpose:** fail if any **production** dependency has a known advisory of severity high or critical.
- **Flags:** `--omit=dev` ignores devDependencies (not shipped); `--audit-level=high` sets the exit-code threshold
  (moderate and low are reported but don't fail).
- **Reads:** the lockfile plus the registry's advisory database (network).
- **Why this early:** a cheap check that fails before spending minutes on tests.
- **Important property:** it is **time-dependent**. The same commit can pass today and fail tomorrow when a new
  advisory is published. That is intended (you learn about it), but it means a red run is not always caused by the
  diff.
- **Context:** Auth needed `overrides` (`deepmerge-ts 8.0.2`, `mysql2 3.24.5`) in `package.json` to pass, because the
  Prisma CLI pulls those in (security-review S-14).
- **Alternatives:** `osv-scanner`, Dependabot/Renovate alerts (continuous, open PRs), Snyk. Audit in CI plus a bot
  is the usual pair.

#### `run: npm run lint` → `eslint .`
- Static analysis: unused vars, unsafe patterns, import rules (see `eslint.config.js`). It reads only sources, with no
  network and no side effects. It is cheap, so it runs before tests.

#### `run: npm run typecheck` → `tsc --noEmit`
- Full TypeScript type check without writing JS. Catches contract-level bugs (wrong field names, missing
  `await` on typed promises) that tests might not exercise. It is separate from `build` because `build` uses
  `tsconfig.build.json` (sources only), while `typecheck` includes tests.

#### `name: Migrations apply cleanly to an empty database` → `npm run db:deploy` → `prisma migrate deploy`
- **Purpose:** apply every migration in `prisma/migrations/` in order to `auth_db`, exactly as the production
  migrate task does.
- **Internals:** reads the `_prisma_migrations` table (creates it if absent), applies each pending folder's
  `migration.sql` in name order, and records each as applied together with a checksum. It never generates migrations,
  never resets data and never prompts. Editing an **already-applied** migration is how you break this: other
  environments won't re-run it, and `prisma migrate dev` will report the checksum mismatch. Fix forward with a new
  migration instead.
- **Why it's here:** it proves the migration history builds a schema from zero. Without it, a broken migration would
  first fail in the production migrate task.
- **Production-suitable:** yes. This is the only Prisma migrate command meant for shared environments.

#### `name: schema.prisma has no changes missing a migration`
```bash
psql "postgresql://auth_svc:auth_local_pw@localhost:5432/postgres" -c "CREATE DATABASE auth_shadow"
npm run db:check-drift   # prisma migrate diff --from-migrations prisma/migrations --to-schema prisma/schema.prisma --exit-code
```
- **Purpose:** catch "edited `schema.prisma`, forgot `prisma migrate dev`".
- **Internals:** `--from-migrations` replays all migrations into the **shadow database** (`SHADOW_DATABASE_URL`) to
  learn the resulting schema, then diffs it against `--to-schema`. `--exit-code`: 0 = no difference,
  **2 = difference**, 1 = error.
- **Why `psql` first:** the shadow DB must exist. `psql` is preinstalled on `ubuntu-latest`.
- **Alternative:** `prisma migrate dev --create-only` would also detect drift, but it is interactive and writes files.
  Never use `migrate dev` in CI.

#### `name: Unit + integration tests` → `npm test` → `vitest run`
- **What happens** ([vitest.config.ts](ecommerce-auth-service/vitest.config.ts), [tests/global-setup.ts](ecommerce-auth-service/tests/global-setup.ts)):
  1. Global setup connects to the `postgres` maintenance DB and runs `DROP DATABASE IF EXISTS "auth_test" WITH (FORCE)`
     and `CREATE DATABASE "auth_test"`, then `npx prisma migrate deploy` against it. Tests run on the **real
     migrated schema**, not on `prisma db push`.
  2. `fileParallelism: false`: test files run one at a time because they share one DB. This is slower but deterministic.
  3. Messaging tests create SNS topics and SQS queues in Floci with a **per-run prefix** (`t-xxxxxxxx-`) and delete
     them afterwards. [test-cleanup.ts](ecommerce-auth-service/tests/test-cleanup.ts) **refuses** to delete anything
     whose prefix doesn't match `^(t|test)-[a-z0-9-]{6,}-$`, a guard against wiping real queues.
  4. Some tests check generated artifacts: OpenAPI must equal what the code generates (the step name says so), and
     `event-schemas.test.ts:48` runs `scripts/verify-contracts.mjs`, which fails if a vendored contract file's SHA-256
     differs from `contracts.lock.json`.
- **⚠ Never** point `TEST_DATABASE_URL` at a database you care about. Global setup **drops** it with `FORCE`
  (disconnecting users). The same holds for every Postgres service, and Order's setup runs `dropDatabase()` on
  `TEST_MONGODB_URI`.
- **What a failure means:** behavior regression, schema/contract drift, or (less often) a flaky emulator. The
  test name says which.

#### `run: npm run build` → `prisma generate && tsc -p tsconfig.build.json`
- Compiles to `dist/`. Typecheck already passed, so the compile here proves the **build config** works (paths,
  emitted output). The output is discarded, because the Docker job builds again from source.

## 3. Job `docker` (lines 63–72)

```yaml
docker:
  needs: test
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: docker/setup-buildx-action@v3
    - name: Build runtime and migrate images (not pushed until Phase 7)
      run: |
        docker buildx build --target runtime -t ecommerce-auth-service:${{ github.sha }} --load .
        docker buildx build --target migrate -t ecommerce-auth-service-migrate:${{ github.sha }} --load .
```

| Piece | Meaning |
|---|---|
| `needs: test` | Images only from code that passed. The job runs on a **new VM**, so it checks out again |
| `setup-buildx-action` | Creates a BuildKit builder (parallel stages, `--target`, cache backends, multi-platform) |
| `--target runtime` / `migrate` | Builds up to that stage of the multi-stage Dockerfile. Both must build, or the deploy would fail later |
| `-t name:${{ github.sha }}` | Tags with the commit, so the image is traceable to source |
| `--load` | Puts the image into the runner's local Docker (otherwise a buildx image stays in the builder cache only) |
| `.` | Build context = the repo; `.dockerignore` decides what is sent |

**What it proves:** the Dockerfile still works (dependency stage, compile stage, non-root user, CMD). **What it
doesn't:** that the image **starts** (no `docker run` smoke test), that it is free of OS vulnerabilities (no scan),
or that it is the image deployed later (deploy rebuilds; see J-3). **Cost:** no layer cache (`cache-from` is absent
in backends), so every run rebuilds `npm ci` from scratch. The frontend uses `type=gha` caching; backends could too.

## 4. Per-service differences

| Repo | Services | Extra / different steps | Why |
|---|---|---|---|
| auth | postgres, floci | `db:deploy` + shadow DB + `db:check-drift` | Prisma's own drift tooling |
| inventory | postgres, floci | `migration:run && migration:revert && migration:run`; `db:check-drift` = `typeorm-ts-node-commonjs migration:generate src/database/migrations/Drift -d src/database/data-source.ts --check` | `--check` exits 1 if entities would generate a migration (and writes nothing). Tests run with **Jest + ts-jest** (`maxWorkers: 1`), not Vitest |
| order | **mongo:8**, floci | **no migration step**. Health check `mongosh … ping`, 10 s × 10 | MongoDB has no schema migrations here. Tests' global setup runs `dropDatabase()` + `syncIndexes()`, so the unique idempotency index is real |
| payment / saga / notification | postgres, floci | `db:migrate && db:rollback && db:migrate` (node-pg-migrate `up`/`down`) | Proves the SQL `down` sections work |

**The "round-trip" is narrower than its name.** `typeorm migration:revert` and `node-pg-migrate down` revert
**only the last migration** by default. So Inventory's round-trip tests only the newest migration's `down`, and
the node-pg-migrate repos currently have one migration, so it's complete for now. Product's Alembic
`downgrade base` reverts **all** of them. To test every `down`: `node-pg-migrate down --count 999` or loop
`migration:revert` until none remain. Note also that a **production** rollback strategy here is
**forward-only** (runbooks.md §3), so `down` migrations matter mostly for local work.

## 5. The ordering, justified

```
checkout → runtime → locked install → audit → lint → typecheck → migrations (+ drift) → tests → build ║ image build
 (files)   (Node 24)   (exact deps)    (cheap)  (cheap)  (cheap)   (schema OK before tests use it)
```

1. **Install before everything**: every later tool comes from `node_modules`.
2. **Cheap, deterministic checks first** (audit seconds, lint and typecheck tens of seconds), so a typo fails in 1 minute, not 6.
3. **Migrations before tests**: tests assume the schema. A migration failure reported as 200 test failures is noise.
4. **Tests before build**: the build output isn't used by tests (Vitest runs TS directly), so building last only costs
   time when everything else passed.
5. **Image build in a separate job after tests**: it parallelizes poorly with tests on one VM, and gating on tests keeps
   images for broken code from ever existing.

**What's missing that a production pipeline usually adds (not mandatory, judged for this project):**
coverage reporting (useful as a trend, not proof); a container scan (Trivy/Grype) of the built image (cheap, high
value); a `docker run` smoke test hitting `/health/live` (catches a CMD/entrypoint mistake the build can't);
`gitleaks` (the repos have `.gitleaks.toml`, but **no workflow runs it**; the security review ran it by hand);
and `actionlint` for the repo's own workflows (only infra lints its workflows in CI).
