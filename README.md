# ecommerce-infrastructure

Platform-level infrastructure and architecture for the e-commerce microservices
platform. This repository contains **no application code**.

| Path | Contents |
|---|---|
| [`docs/architecture/`](docs/architecture/README.md) | Architecture, conventions, messaging topology, checkout saga, local dev, checklist |
| [`compose.yaml`](compose.yaml) | Local environment: PostgreSQL, MongoDB, LocalStack (SNS/SQS), Mailpit, and all services (`--profile apps`) |
| [`local/`](local/) | Database init scripts: one database and one role per service |
| [`terraform/modules/messaging`](terraform/modules/messaging) | SNS topics, SQS queues, DLQs, subscriptions, queue policies, per-service IAM documents, alarms |
| [`terraform/environments/`](terraform/environments) | `local` (LocalStack), `dev`, `staging`, `prod`: isolated state per environment |
| [`scripts/create-github-repos.sh`](scripts/create-github-repos.sh) | Creates and pushes the independent GitHub repositories |
| [`scripts/verify-local-messaging.sh`](scripts/verify-local-messaging.sh) | End-to-end check of SNS → SQS routing in LocalStack |

## Quick start

```bash
docker compose up -d                          # infrastructure only
docker compose --profile apps up -d --build   # + all services and frontend
```

See [local-development.md](docs/architecture/local-development.md).

## Safety

- `dev`, `staging` and `prod` use a partial S3 backend. They cannot be planned
  or applied until a `backend.hcl` is created. **Nothing in this repository
  creates real AWS resources unless someone runs `terraform apply` against
  those environments with credentials.**
- CI runs `fmt`, `init -backend=false` and `validate` only. It holds no AWS credentials.
- Production deployment (Phase 7) will use GitHub OIDC → IAM role. No long-lived keys.

## Validate locally

```bash
cd terraform && terraform fmt -check -recursive
for d in modules/messaging environments/*; do (cd $d && terraform init -backend=false && terraform validate); done
docker compose --profile apps config --quiet
```
