# Phase A.3: Local Development and Docker Architecture

Source: [ecommerce-infrastructure/compose.yaml](ecommerce-infrastructure/compose.yaml) (396 lines), each repo's
`Dockerfile` and `compose.yaml`. Nothing in this file was executed for this analysis.

---

## 1. Two ways to run locally

| Mode | Command (run inside `ecommerce-infrastructure/`) | What starts |
|---|---|---|
| Infrastructure only | `docker compose up -d` | postgres, mongo, floci, messaging-init, mailpit |
| Whole platform | `docker compose --profile apps up -d --build` | the above + 7 `*-migrate` jobs + 7 services + frontend |
| One service alone | `docker compose up -d` **inside that service's repo** | only that service's own database (each repo has a small `compose.yaml`) |

Your laptop is 8 GB. The full profile swaps (see memory note). Prefer running infrastructure plus the 1–2
services you are working on, e.g. `docker compose --profile apps up -d --no-deps auth-service`. Remember that
`--no-deps` **skips the `<svc>-migrate` job**, so run it explicitly after schema changes:
`docker compose --profile apps run --rm auth-migrate`.

## 2. Topology

```mermaid
flowchart LR
    B[Browser] -->|:5173| FE["frontend<br/>nginx-unprivileged :8080"]
    B -->|:4001-4007 direct, CORS| SVC
    B -->|:8025| MP[mailpit UI]
    subgraph compose network "ecommerce_default" (container DNS = service name)
        SVC["auth 4001 · product 4002 · inventory 4003 · order 4004<br/>payment 4005 · notification 4006 · saga 4007"]
        PG[("postgres:17-alpine :5432<br/>6 DBs, 6 roles")]
        MG[("mongo:8 :27017")]
        FL["floci/floci:2.0.1 :4566<br/>SNS/SQS emulator, hybrid persistence"]
        MI["messaging-init<br/>terraform 1.16.2 apply → Floci"]
        MPS["mailpit SMTP :1025"]
        MIG["*-migrate one-off jobs"]
    end
    SVC --> PG & MG & FL & MPS
    MIG --> PG & MG
    MI --> FL
```

**Locally the browser calls each service on its own port** (`VITE_*_API_URL=http://localhost:400x`), so CORS is
in play. In AWS everything is one origin behind CloudFront (`/api/*` → ALB), so CORS disappears and the cookies
are first-party. This is one of the biggest differences between local and production.

## 3. Startup ordering (what `depends_on` really guarantees)

```
postgres (healthy) ──► <svc>-migrate (completed_successfully) ──► <svc>
floci (healthy) ──► messaging-init (completed_successfully) ──► every publishing/consuming service
mailpit (healthy) ──► auth, notification
auth-service (service_started) ──► product, inventory, order, payment, saga
```

- `service_completed_successfully` is a real gate: a failed migration stops the service from starting. Good.
- `service_started` only means the **container process started**, not that Auth is ready to serve JWKS.
  It works because verifiers fetch JWKS lazily on the first token and cache it. Every image already defines a
  `HEALTHCHECK` (`/health/live`), so `condition: service_healthy` would be stricter.
- **Readiness ≠ startup order.** Services also expose `/health/ready` (DB and dependencies). In ECS the ALB uses
  `/health/ready` ([service/main.tf:333-338](ecommerce-infrastructure/terraform/modules/service/main.tf#L333-L338)),
  while the container health check uses `/health/live`.

## 4. The common Dockerfile pattern (multi-stage)

Example: [saga Dockerfile](ecommerce-saga-orchestrator/Dockerfile).

| Stage | Purpose | Notes |
|---|---|---|
| `build` (`node:24-alpine`) | `npm ci` (all deps), `tsc` | `package*.json` is copied first, so the dependency layer is cached until the lockfile changes |
| `prod` | `npm ci --omit=dev`, copy `dist/` and SQL migrations, `USER node` | Smaller attack surface, non-root |
| `migrate` (FROM prod) | `CMD npx node-pg-migrate up …` | `node-pg-migrate` is a **production** dependency in saga/payment/notification, so `npx` does not download at runtime (checked) |
| `runtime` (last = default) | `EXPOSE`, `HEALTHCHECK wget /health/live`, `CMD node dist/server.js` | CI builds `--target runtime` and `--target migrate` |

Per-repo variations worth knowing:

| Repo | Variation | Why |
|---|---|---|
| Auth | `migrate` is FROM `build` (has the Prisma CLI). `runtime` uses `npm ci --omit=dev --omit=optional --omit=peer --ignore-scripts` | Keeps the ~250 MB Prisma CLI and engines out of the runtime image ([Dockerfile comments](ecommerce-auth-service/Dockerfile)). The migrate image still contains the CLI (finding S-5, accepted) |
| Order | Extra `certs` stage | Ships the RDS CA bundle for DocumentDB TLS |
| Product | `python:3.14-slim`, `pip install -r requirements.txt` (pinned), uid 10001 | `migrate` runs `alembic upgrade head` |
| Frontend | `build` with `ARG VITE_*` → `nginxinc/nginx-unprivileged:1.29-alpine` on 8080 | `VITE_*` values are **baked in at build time** (build args, not runtime env). Production does **not** use this image: the SPA is synced to S3 |

**Build args vs runtime env:** only the frontend uses build args (its config ends up inside the JS bundle). Every
backend reads config at **runtime** from env vars, validated by Zod/Pydantic at boot, and refuses to start on
invalid config. The images therefore contain no environment-specific values and no secrets.

## 5. Local vs CI vs production

| Concern | Local compose | CI (GitHub Actions `services:`) | Production design (ECS) |
|---|---|---|---|
| Databases | one postgres container, 6 DBs; mongo:8 | one fresh postgres/mongo per job | one RDS PostgreSQL 17 (6 DBs), DocumentDB 5 |
| AWS | Floci emulator, `AWS_ACCESS_KEY_ID=test` | Floci 2.0.1 service container | real SNS/SQS through VPC endpoints, task IAM roles |
| Topology creation | `messaging-init` runs the **same Terraform module** with `-auto-approve` against Floci | tests create their own prefixed queues and delete them afterwards | `terraform apply` (manual, approved) |
| Secrets | plain local values in compose (`*_local_pw`, client secret hashes; allowlisted in `.gitleaks.toml`) | throwaway passwords in workflow env | Secrets Manager per service; RDS-managed master password |
| Payment provider | `mock` (signs real HMAC webhooks) | mock + Stripe adapter tested offline | `stripe`; the service refuses `mock` when `NODE_ENV=production` ([payment env.ts:61-64](ecommerce-payment-service/src/config/env.ts#L61-L64)) |
| Email | Mailpit | in-test fakes | SES SMTP |
| Migrations | `*-migrate` compose jobs | `db:deploy` / `migration:run` / `alembic upgrade` steps | one-off ECS task before each rollout |
| Container user | non-root | n/a | non-root, `readonlyRootFilesystem = true`, `enable_execute_command = false` ([service/main.tf:267-268](ecommerce-infrastructure/terraform/modules/service/main.tf#L267-L268), [:367](ecommerce-infrastructure/terraform/modules/service/main.tf#L367)) |
| Orchestration | restart `unless-stopped`, no autoscaling, no rolling deploys | none | ECS service, circuit-breaker rollback, autoscaling, `minimum_healthy_percent=100` |

Why compose is not production orchestration: it gives you no rolling deploys, no health-based rollback, no
multi-AZ, no IAM, no autoscaling and no secret store. Ports are published straight to your host, and one Postgres
process is a single point of failure for everything.

## 6. Commands you will use (and their dangers)

| Command | Use | Caution |
|---|---|---|
| `docker compose --profile apps up -d --build` | build and start everything | heavy on 8 GB; rebuilds every image |
| `docker compose logs -f saga-orchestrator` | follow one service | logs are pino JSON; use `\| npx pino-pretty` |
| `docker compose exec postgres psql -U saga_svc -d saga_db` | inspect saga state | read-only habits: `SELECT state, count(*) FROM saga_instances GROUP BY 1` |
| `docker compose --profile apps run --rm auth-migrate` | apply migrations after a schema change | needed after `--no-deps` |
| `docker compose down` | stop, **keep** volumes | safe |
| `docker compose down -v` | stop and **delete volumes** | **Destroys** all local DB data and the Auth signing key volume (`auth-keys`), so every existing session becomes invalid |
| `rm -rf .floci-data` | reset the emulator | queues/topics come back on the next `messaging-init` |
| `scripts/clean-test-topology.sh` | remove test queues left in Floci | — |

Warnings that apply here:
- **Exposed DB ports** (`5432`, `27017`) are bound to all interfaces with known passwords. Fine on a laptop, not
  on a shared network. Binding to `127.0.0.1:5432:5432` would be safer.
- **Never reuse** compose credentials anywhere; the file says so ([compose.yaml:8](ecommerce-infrastructure/compose.yaml#L8)).
- Floci deliberately does **not** mount `/var/run/docker.sock` (root-equivalent host access). Keep it that way.
