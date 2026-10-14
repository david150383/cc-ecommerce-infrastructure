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
| AWS CLI v2 | any | Inspecting Floci queues (`aws --endpoint-url http://localhost:4566 sqs list-queues`) |

## Two ways to work

**1. Shared infrastructure, one service on your host (the usual loop):**

```bash
cd ecommerce-infrastructure
docker compose up -d                      # postgres, mongo, floci, mailpit
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
| Floci (AWS emulator) | http://localhost:4566 (health: `/_floci/health`) |
| PostgreSQL | `localhost:5432` (per-service users, see `local/postgres/init.sql`) |
| MongoDB | `localhost:27017` |

## End-to-end checks

| Script | What it proves |
|---|---|
| `scripts/verify-local-messaging.sh` | SNS → SQS routing and filter policies in Floci |
| `scripts/verify-service-messaging.py` | Auth/Inventory/Order publish and consume over the real queues (the saga's steps by hand) |
| `scripts/verify-checkout-saga.py` | The full checkout through the Saga Orchestrator and the real Payment Service: happy path, admin refund, out of stock, payment declined, timeout + late payment refunded, a saga SIGKILLed mid-checkout that resumes, forged webhook rejected, DLQs empty |

No stubs: payments go through the real Payment Service with the **mock provider**. The script clicks Pay or
Decline on the mock's hosted checkout page (`http://localhost:4005/mock-provider/checkout/…`), which sends signed
webhooks, exactly what a browser user would do. Beyond the cases above it checks an admin refund, a late payment
after a timeout (refunded automatically by the saga), and that a forged webhook is rejected. Run the saga with a
short payment timeout:

```bash
SAGA_PAYMENT_TIMEOUT_SECONDS=15 docker compose --profile apps up -d --no-build --no-deps saga-orchestrator
ADMIN_PASSWORD='…' python3 -u scripts/verify-checkout-saga.py
docker compose --profile apps up -d --no-build --no-deps saga-orchestrator   # back to the defaults
```

`--no-deps` matters: plain `up <service>` re-runs every one-off dependency job (migrations, Terraform), which
takes minutes on a busy laptop.

### Stripe test mode instead of the mock

Put `PAYMENT_PROVIDER=stripe`, `STRIPE_SECRET_KEY=sk_test_…` and `STRIPE_WEBHOOK_SECRET=whsec_…` in a git-ignored
`.env` next to `compose.yaml`, run `stripe listen --forward-to localhost:4005/api/v1/payments/webhooks/stripe`
(it prints the `whsec_…`), and recreate `payment-service`. Live keys are refused outside `NODE_ENV=production`.

## Accounts and credentials (local only)

| What | Value |
|---|---|
| Admin user | `ADMIN_PASSWORD='…' npm run admin:create -- admin@shop.local` in `ecommerce-auth-service`, or via `docker compose --profile apps run --rm -e ADMIN_PASSWORD='…' auth-migrate npx tsx src/scripts/create-admin.ts admin@shop.local` |
| Service clients | `ecommerce-order-service` / `order-service-local-secret`, `ecommerce-saga-orchestrator` / `saga-orchestrator-local-secret`, `ecommerce-payment-service` / `payment-service-local-secret` (hashes in `SERVICE_CLIENTS` of auth-service) |
| Mock payment webhook secret | `local-mock-webhook-secret` |
| Demo catalog | `docker compose --profile apps exec product-service python -m app.seed` (idempotent) |

## Messaging resources

```bash
cd terraform/environments/local
terraform init
terraform apply      # creates topics/queues inside Floci only (32 resources)
cd ../../..
scripts/verify-local-messaging.sh   # publishes sample events, checks filter-policy routing
```

Floci runs with `FLOCI_STORAGE_MODE=hybrid` and keeps state in `./.floci-data` (git-ignored), so topics and
queues survive restarts. To reset messaging: stop Floci, delete `./.floci-data` and
`terraform/environments/local/terraform.tfstate`, start Floci, apply again.

Inspect queues by hand:

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://localhost:4566 sqs list-queues
aws --endpoint-url http://localhost:4566 sns list-subscriptions
```

## Floci

The compose file runs `floci/floci:2.0.1` without mounting the Docker socket: we only use SNS, SQS, IAM and
CloudWatch, and the socket is only needed for container-backed services (Lambda, RDS, ECS, …) while giving
the container root-equivalent access to the host. If another project already uses port 4566, set
`FLOCI_PORT` in `.env` (and point host-side tools at that port).

Queue URLs returned by Floci use the hostname `floci` (`FLOCI_HOSTNAME`), which resolves inside the compose
network only. Services therefore address queues by **name** and configure their SQS client with
`useQueueUrlAsEndpoint: false`, so the configured endpoint is always used.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `docker build` hangs at `resolve image config for docker/dockerfile:1` | BuildKit can stall fetching the syntax frontend through Docker Desktop's proxy. Our Dockerfiles intentionally have no `# syntax=` line |
| `docker compose up --build <svc>` rebuilds unrelated services | `--build` rebuilds the whole dependency chain. Build only what changed (`docker compose build <svc>`), then `up -d --no-build` |
| `npm error code ECONNRESET` during image builds | A flaky connection to the npm registry; re-run the build (only the failed images) |
| `npm ci` fails in Docker with `Missing: ... from lock file` | Lockfile generated on macOS lacks Linux-only optional deps. Delete `node_modules` and `package-lock.json`, run `npm install`, and verify with `docker run --rm -v "$PWD:/app" -w /app node:24-alpine npm ci --ignore-scripts` |
| Mongo stays `health: starting` | `mongosh` is slow to start under load; the healthcheck allows 15s plus a 30s start period |
| Published events don't appear in a queue immediately | SNS → SQS delivery is asynchronous. Long-poll (`--wait-time-seconds`) instead of reading once |
| `no space left on device` | Docker build cache grows without bound: `docker builder prune` |

## Resetting

```bash
docker compose down -v   # removes containers AND data volumes
```
