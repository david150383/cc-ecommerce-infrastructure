# Local Development

## Layout

Clone every repository side by side (this folder is **not** a repository itself):

```
workspace/
├── ecommerce-auth-service/
├── ecommerce-product-service/
├── ecommerce-inventory-service/
├── ecommerce-order-service/
├── ecommerce-saga-orchestrator/
├── ecommerce-payment-service/
├── ecommerce-notification-service/
├── ecommerce-frontend/
└── ecommerce-infrastructure/   ← run docker compose from here
```

## Prerequisites

| Tool | Version | Used by |
|---|---|---|
| Docker Desktop | 4.x+ (Engine 27+) | Everything |
| Node.js | 24 LTS (22+ works) | Node services, frontend |
| Python | 3.14 | Product Service |
| Terraform | 1.9+ | Infrastructure |
| AWS CLI v2 | any | Inspecting LocalStack queues (`aws --endpoint-url http://localhost:4566 sqs list-queues`) |

## Two ways to work

**1. Shared infrastructure, one service on your host (the usual loop):**

```bash
cd ecommerce-infrastructure
docker compose up -d                      # postgres, mongo, localstack, mailpit
cd ../ecommerce-auth-service
cp .env.example .env
npm install && npm run dev                # hot reload on :4001
```

**2. Everything in containers (integration testing):**

```bash
cd ecommerce-infrastructure
docker compose --profile apps up -d --build
docker compose ps
```

**3. A service completely on its own:** each service repo also has a
`compose.yaml` that starts only its own database on a non-conflicting port.
This proves the service is independently runnable.

## Endpoints

| What | URL |
|---|---|
| Frontend | http://localhost:5173 |
| Auth / Product / Inventory / Order / Payment / Notification / Saga | http://localhost:4001 … 4007 |
| Mailpit (captured email) | http://localhost:8025 |
| LocalStack | http://localhost:4566 |
| PostgreSQL | `localhost:5432` (per-service users, see `local/postgres/init.sql`) |
| MongoDB | `localhost:27017` |

## Accounts and credentials (local only)

| What | Value |
|---|---|
| Admin user | `ADMIN_PASSWORD='…' npm run admin:create -- admin@shop.local` in `ecommerce-auth-service`, or via `docker compose --profile apps run --rm -e ADMIN_PASSWORD='…' auth-migrate npx tsx src/scripts/create-admin.ts admin@shop.local` |
| Service clients | `ecommerce-order-service` / `order-service-local-secret`, `ecommerce-saga-orchestrator` / `saga-orchestrator-local-secret`, `ecommerce-payment-service` / `payment-service-local-secret` (hashes in `SERVICE_CLIENTS` of auth-service) |
| Demo catalog | `docker compose --profile apps exec product-service python -m app.seed` (idempotent) |

## Messaging resources

```bash
cd terraform/environments/local
terraform init
terraform apply      # creates topics/queues inside LocalStack only (32 resources)
cd ../../..
scripts/verify-local-messaging.sh   # publishes sample events, checks filter-policy routing
```

LocalStack keeps state in the `localstack-data` volume. After `docker compose down -v`,
delete `terraform/environments/local/terraform.tfstate` and apply again.

Inspect queues by hand:

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://localhost:4566 sqs list-queues
aws --endpoint-url http://localhost:4566 sns list-subscriptions
```

## LocalStack versions

The compose file pins `localstack/localstack:4.14`, the last 4.x release. If you
move to a calendar-versioned image (`2026.x`), create a free LocalStack account
and set `LOCALSTACK_AUTH_TOKEN` in `.env`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `docker build` hangs at `resolve image config for docker/dockerfile:1` | BuildKit can stall fetching the syntax frontend through Docker Desktop's proxy. Our Dockerfiles intentionally have no `# syntax=` line |
| `npm ci` fails in Docker with `Missing: ... from lock file` | Lockfile generated on macOS lacks Linux-only optional deps. Delete `node_modules` and `package-lock.json`, run `npm install`, and verify with `docker run --rm -v "$PWD:/app" -w /app node:24-alpine npm ci --ignore-scripts` |
| Mongo stays `health: starting` | `mongosh` is slow to start under load; the healthcheck allows 15s plus a 30s start period |
| Published events don't appear in a queue immediately | SNS → SQS delivery is asynchronous. Long-poll (`--wait-time-seconds`) instead of reading once |
| `no space left on device` | Docker build cache grows without bound: `docker builder prune` |

## Resetting

```bash
docker compose down -v   # removes containers AND data volumes
```
