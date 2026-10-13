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

## Messaging resources (Phase 3)

```bash
cd terraform/environments/local
terraform init
terraform apply      # creates topics/queues inside LocalStack only
```

## LocalStack versions

The compose file pins `localstack/localstack:4.14`, the last 4.x release. If you
move to a calendar-versioned image (`2026.x`), create a free LocalStack account
and set `LOCALSTACK_AUTH_TOKEN` in `.env`.

## Resetting

```bash
docker compose down -v   # removes containers AND data volumes
```
