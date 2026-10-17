# Phase J-2: Product (Python), Frontend, Contracts, Infrastructure CI and the Nightly E2E

---

## 1. Product Service `ci.yml` (Python)

File: [ecommerce-product-service/.github/workflows/ci.yml](ecommerce-product-service/.github/workflows/ci.yml).
Header, permissions, concurrency and the `docker` job match the Node repos (J-1). Only Postgres is a service
(Product does no messaging). `DATABASE_URL` uses the SQLAlchemy driver prefix `postgresql+psycopg://`.

| # | Step | What it does / flags | Why here | Notes |
|---|---|---|---|---|
| 1 | `actions/setup-python@v5` with `python-version-file: .python-version` (`3.14`), `cache: pip`, `cache-dependency-path: requirements-dev.txt` | Installs CPython 3.14.x; caches pip's download cache keyed by the requirements file hash | Same minor as the image `python:3.14-slim` | Without `cache-dependency-path` the cache key wouldn't follow your real lock file |
| 2 | `pip install -r requirements-dev.txt && pip install --no-deps -e .` | Installs **43 pinned** (`==`) runtime + dev packages, then the app itself in **editable** mode **without resolving deps** | `--no-deps` guarantees nothing outside the pinned file sneaks in through `pyproject.toml` ranges | Pins are versions, not hashes. `pip install --require-hashes` (via `pip-compile --generate-hashes` / `uv pip compile`) would also prevent a tampered re-upload |
| 3 | `pipx run pip-audit==2.10.0 -r requirements.txt --disable-pip --no-deps --progress-spinner off` | Audits the **runtime** pins (not dev) against PyPI/OSV advisories | Python's equivalent of `npm audit --omit=dev` | `pipx run` uses an isolated, pinned tool. `--disable-pip --no-deps` = "trust my fully pinned list, don't resolve". Like npm audit, it is **time-dependent** |
| 4 | `ruff check .` | Lint: rules `E,F,I,B,UP,S,ASYNC` ([pyproject.toml](ecommerce-product-service/pyproject.toml)). `S` = bandit security rules; `S104` (bind 0.0.0.0) ignored on purpose | Cheap, before DB work | `I` = import sorting |
| 5 | `ruff format --check .` | Fails if any file isn't formatted (writes nothing) | Formatting debates end in CI | Locally: `ruff format .` to fix |
| 6 | `alembic upgrade head && alembic downgrade base && alembic upgrade head` | Apply all → **revert all** → apply all | Proves every `downgrade()` works, and that upgrade is repeatable on a DB that had the schema before | Stronger than the Node round-trips (those revert only the last migration) |
| 7 | `alembic check` | Compares SQLAlchemy models with the migrated DB; fails if `autogenerate` would emit operations | "Changed a model, forgot the migration" | Equivalent of `prisma migrate diff --exit-code` |
| 8 | `pytest` | `testpaths=tests`, `-q`, and **`filterwarnings = ["error", …]`**: any warning fails the run (one documented Alembic warning ignored) | Behavior | Turning warnings into errors catches deprecations early. `tests/test_openapi.py` asserts the committed `openapi/openapi.json` equals what the code generates |

There is no type checker (`mypy`/`pyright`) in Product CI. That fits the project (Pydantic validates at runtime), but
it is the one backend without static type checking. Optional, P3.

## 2. Frontend `ci.yml`

File: [ecommerce-frontend/.github/workflows/ci.yml](ecommerce-frontend/.github/workflows/ci.yml). There are no
service containers: unit/component tests mock `fetch`.

| Step | Detail |
|---|---|
| `npm ci`, `npm audit --omit=dev --audit-level=high`, `npm run lint` | as in J-1 |
| **`npm run contracts:types && git diff --exit-code src/api/generated`** | [generate-api-types.mjs](ecommerce-frontend/scripts/generate-api-types.mjs) runs `openapi-typescript` on every pinned `contracts/openapi/*.openapi.json` → `src/api/generated/*.ts`. `git diff --exit-code` fails if the regenerated files differ from the committed ones. It catches "re-vendored contracts, forgot to regenerate types" and hand-edits of generated files. This is the **"regenerate and diff"** pattern, worth reusing anywhere code is generated |
| `npm run typecheck` → `tsc && tsc -p tsconfig.e2e.json` | Includes [src/api/contract-check.ts](ecommerce-frontend/src/api/contract-check.ts): compile-time assertions `Assignable<PublishedType, TypeTheUIReads>`. If a pinned API stops providing a field the UI reads, **the typecheck fails**. The second `tsc` type-checks the Playwright tests |
| `npm test` → `vitest run` | component/page tests (RTL), routes, checkout logic, env parsing; `src/test/contracts.test.ts` runs the vendored-file verifier |
| `npm run build` → `tsc && vite build` | Production bundle; `VITE_*` default to local values here (the real values are injected in the deploy job) |
| Job `docker`: `docker/build-push-action@v6` with `push: false`, `cache-from: type=gha`, `cache-to: type=gha,mode=max` | Builds the nginx image with the **GitHub Actions cache backend**; `mode=max` caches every intermediate layer (bigger cache, faster rebuilds). This image is **only for local/compose**: production serves `dist/` from S3 |

Not in PR CI: Playwright E2E. It needs the whole platform, so it runs in the infra nightly `e2e.yml`.

## 3. Contracts `ci.yml`

File: [ecommerce-contracts/.github/workflows/ci.yml](ecommerce-contracts/.github/workflows/ci.yml). Triggers include
**tags `v*`**, so a release tag is re-verified.

| Step | Detail |
|---|---|
| `actions/checkout@v4` with **`fetch-depth: 0`** | Full history **and tags**. `compat` runs `git describe --tags --abbrev=0 --match v*` and `git show <tag>:<file>`, which fail with the default shallow clone |
| `npm ci`, `npm audit`, `npm run lint` | as above |
| `npm test` (Vitest: `tests/contracts.test.mjs`, `tests/compat.test.mjs`) | Every schema compiles (Ajv 2020-12, strict); every example validates; **ownership rules** (an event's owner is its producer, a command's owner is its consumer); the compat rules themselves are unit-tested |
| `npm run check` → `node scripts/build.mjs --check` | Regenerates `asyncapi/asyncapi.json` and `docs/OWNERSHIP.md` in memory and fails if the committed files are stale. The same "regenerate and diff" pattern |
| **`npm run compat`** → [scripts/compat.mjs](ecommerce-contracts/scripts/compat.mjs) | Loads every schema + OpenAPI at the **latest tag** and in the working tree, classifies each change `breaking / warning / safe` **from the reader's side** ([lib/compat.mjs](ecommerce-contracts/lib/compat.mjs)), computes the required bump (breaking → MAJOR, addition → MINOR), compares with `package.json` version, and exits 1 if the bump is too small |

Example compat output (**illustrative**, the format is from the script, the content is hypothetical):
```
Compared with v1.3.0: 2 change(s)
  ✗ BREAKING  OrderConfirmed v1  payload.total: required field removed
  · safe      InventoryReserved v1  payload.warehouseId: optional field added
Version 1.3.0 → 1.4.0 (minor); these changes need at least: major.
✗ Breaking change without a major version. Prefer a NEW version of the message (v2 next to v1) ...
```

## 4. Infrastructure `ci.yml`

File: [ecommerce-infrastructure/.github/workflows/ci.yml](ecommerce-infrastructure/.github/workflows/ci.yml). Four
independent jobs, run in parallel. **No AWS credentials exist in this workflow.**

### Job `terraform` (matrix over 5 roots: `modules/messaging`, `environments/{local,dev,staging,prod}`)

| Step | Purpose | Flags | Safe for PRs? |
|---|---|---|---|
| `hashicorp/setup-terraform@v3` with `terraform_version: 1.16.2` | Installs an exact Terraform | also installs a wrapper that exposes `stdout`/`exitcode` outputs (harmless here) | yes |
| `terraform fmt -check -recursive` (in `terraform/`) | Fails on unformatted `.tf` | `-check` = don't write; `-recursive` = all subdirs | yes. Runs 5× identically (once per matrix entry); it could be its own job |
| `terraform init -backend=false -input=false` | Downloads providers and modules **without configuring the S3 backend** | `-backend=false` = never touch state, so no credentials are needed; `-input=false` = fail instead of prompting | yes. Uses the committed `.terraform.lock.hcl` of each environment to pin provider versions and hashes |
| `terraform validate` | Syntax, types, references, required args | — | yes. It does **not** contact AWS and does not catch invalid values (e.g. a wrong KMS alias policy) |

### Job `terraform-tests` (matrix over 8 modules)

`terraform init -backend=false -input=false` → `terraform test` in each module. The tests
(`tests/*.tftest.hcl`) use **`mock_provider "aws"`** with `override_during = plan`: Terraform **plans** the module
with fake AWS responses and evaluates `assert { condition = … }` blocks. Examples from
[service.tftest.hcl](ecommerce-infrastructure/terraform/modules/service/tests/service.tftest.hcl):

- circuit breaker enabled with rollback; `deployment_minimum_healthy_percent == 100`
- no `enable_execute_command`, no public IP; non-root user and read-only root FS in the container definitions
- the ALB health check path is `/health/ready`; an internal-only service has **no** listener rule
- `run "root_is_refused"`: plans with `run_as = "0:0"` and `expect_failures = [var.run_as]`, i.e. the test **passes
  only if** the variable's validation rejects running as root (a negative test)

**What these tests are good at:** locking in design decisions (a refactor that turns off rollback fails CI).
**What they cannot catch:** anything only real AWS decides, such as IAM evaluation, KMS key-policy rules (finding P1-1:
alarms on an `aws/sns`-encrypted topic), quotas, name collisions, or region feature gaps.

Module directories have no committed `.terraform.lock.hcl` (only the environments do), so `terraform test` in a
module resolves the newest `~> 6.0` provider on every run. That is mildly non-deterministic (P3).

### Job `workflows`

`uses: docker://rhysd/actionlint:1.7.7` with `args: -no-color` lints **this repo's** workflows (expression
syntax, unknown keys, `needs` typos) and runs **shellcheck** on `run:` blocks. Other repos don't run actionlint in
their CI. The security review claims it was run on all ten by hand.

### Job `compose`

`docker compose --profile apps config --quiet` parses `compose.yaml`, resolves anchors (`<<: *service-defaults`)
and `${VAR:-default}` interpolation, validates the schema, and prints nothing (`--quiet`). It catches YAML/compose
errors without building or starting anything. It **does not** check that the sibling build contexts exist (CI has only
this repo checked out; build contexts aren't validated by `config`).

## 5. Infrastructure `e2e.yml` (nightly and manual)

File: [ecommerce-infrastructure/.github/workflows/e2e.yml](ecommerce-infrastructure/.github/workflows/e2e.yml).
`timeout-minutes: 60`. `env: ADMIN_PASSWORD: e2e only passphrase 2026` is a throwaway value for the throwaway stack.

| Step | Commands | Purpose |
|---|---|---|
| Check out all repos | `git clone --depth 1 https://github.com/${{ github.repository_owner }}/ecommerce-$r.git` ×10 | Build the platform **from the current `main` of each repo**. That is the definition of "do the latest versions work together" |
| Contracts consistent and pinned | in `ecommerce-contracts`: `npm ci && npm test && npm run check`; then `node ../ecommerce-$r/scripts/verify-contracts.mjs ../ecommerce-$r` for 7 repos | Every service's vendored files match the release it claims |
| Start the stack | `SAGA_PAYMENT_TIMEOUT_SECONDS=15 NOTIFICATION_RETRY_BASE_MS=2000 docker compose --profile apps up -d --build --wait`; seed products (`python -m app.seed`); create an admin via `auth-migrate` image | Short timeouts make timeout paths testable in minutes |
| Messaging, saga, notifications | `verify-local-messaging.sh`, `verify-service-messaging.py`, `verify-checkout-saga.py`, `verify-order-cancellation.py`, `verify-notifications.py` | Real queues, real services, real failure paths |
| Browser smoke | `npm ci`, `npx playwright install --with-deps --only-shell chromium`, `npm run e2e` | One sequential user journey |
| Logs on failure | `if: failure()` → `docker compose … logs --no-color --tail 200` | Debuggable red runs |

**As written it cannot run on your GitHub account** (CONFIRMED config):
1. Clone URLs use `ecommerce-$r`, but your repos are `cc-ecommerce-$r` (intentional, so the workflow should take the
   prefix as a variable, e.g. `REPO_PREFIX: cc-`).
2. `ecommerce-contracts` has no remote yet.
3. If the repos are private, anonymous `https://` clones fail. Use `actions/checkout` with `repository:` and a
   token that can read the sibling repos (a fine-grained PAT or a GitHub App token).
4. Its `docker compose` checkouts land side by side as `ecommerce-*`, which matches compose's default build contexts
   (`../ecommerce-auth-service`), so clone **into** `ecommerce-$r` directories even if the repo names differ.

Also verify on the first real run: `docker compose up --wait` together with one-off jobs that exit
(`*-migrate`, `messaging-init`). Compose's handling of exited containers under `--wait` has varied between
versions. **Unverified**, not a confirmed bug.
