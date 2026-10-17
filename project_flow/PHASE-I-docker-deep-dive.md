# Phase I: Docker and Local Development, Deep Dive

Phase A-3 covered the compose topology, startup ordering and local vs CI vs production. This phase goes instruction by
instruction through the images themselves. Read-only: nothing was built or run.

---

## 1. One Dockerfile, line by line: Order Service

[ecommerce-order-service/Dockerfile](ecommerce-order-service/Dockerfile) is the most complete example (it also has the certs stage).

| Instruction | What it does | Why |
|---|---|---|
| `FROM node:24-alpine AS build` | Builder stage on Alpine (small, musl libc) | Same major as `.nvmrc` and CI |
| `COPY package.json package-lock.json ./` then `RUN npm ci` | Install **all** deps (incl. TypeScript) | Copying only the manifests first means this layer is **cached until the lockfile changes**. Source edits don't re-install |
| `COPY tsconfig*.json ./`, `COPY src ./src`, `RUN npm run build` | Compile to `dist/` | Source last: the most frequently changing layer goes on top |
| `FROM node:24-alpine AS certs` + `ARG RDS_CA_SHA256=…` + `wget … && sha256sum -c -` | Download Amazon's RDS CA bundle and **verify its checksum** | A changed or tampered file fails the build instead of silently shipping. The `ARG` lets you update the pin deliberately |
| `FROM node:24-alpine AS prod`, `ENV NODE_ENV=production` | A fresh stage: nothing from `build` except what's copied | The builder's dev deps and source never reach production |
| `RUN npm ci --omit=dev && npm cache clean --force` | Production deps only; drop npm's cache | Smaller image, smaller attack surface |
| `COPY --from=build /app/dist ./dist` | Compiled JS only | — |
| `COPY events/schemas ./events/schemas` | The vendored **command schemas** the SQS consumer validates against | The parser loads them from disk at runtime (Phase L-1 §5) |
| `COPY --from=certs …/rds-global-bundle.pem /app/certs/…` | The CA for DocumentDB TLS | Used automatically for DocumentDB URIs ([mongo.ts](ecommerce-order-service/src/db/mongo.ts)) |
| `USER node` | Run as uid 1000, not root | A container escape starts unprivileged; ECS also enforces `user = run_as` |
| `FROM prod AS migrate` + `CMD ["node", "dist/scripts/sync-indexes.js"]` | The one-off migration image | Same deps and code as runtime, a different command |
| `FROM prod AS runtime` (last stage = default) | The service image | A plain `docker build .` yields the runtime image |
| `EXPOSE 4004` | Documentation only (doesn't publish anything) | Ports are published by compose/ECS |
| `HEALTHCHECK … wget -qO- http://127.0.0.1:${PORT:-4004}/health/live` | The container health check | busybox `wget` exists in Alpine, so no curl is needed. **Liveness**, not readiness (M-2 §3) |
| `CMD ["node", "dist/server.js"]` (**exec form**) | Node is PID 1 and receives SIGTERM directly | Shell form (`CMD node …`) would put `/bin/sh` in between and swallow signals, breaking graceful shutdown. In ECS `initProcessEnabled` adds an init process too |

## 2. All images at a glance

| Image | Stages | Migrate command | Runtime user | Special |
|---|---|---|---|---|
| auth | build → migrate (FROM build) / runtime | `npx prisma migrate deploy` | node | runtime `npm ci --omit=dev --omit=optional --omit=peer --ignore-scripts` keeps the ~250 MB Prisma CLI out; the Prisma client is pre-generated in `dist`; `/app/keys` 0700 for local keys |
| product | base → migrate / runtime | `alembic upgrade head` | uid 10001 (`useradd --system`) | pinned `requirements.txt` first (cached layer), then `pip install --no-deps .`; healthcheck via Python `urllib` (no wget in slim) |
| inventory | build → prod → migrate / runtime | `node node_modules/typeorm/cli.js migration:run -d dist/database/data-source.js` | node | "decorator metadata requires tsc, not esbuild"; ships `events/schemas` |
| order | build, certs → prod → migrate / runtime | `node dist/scripts/sync-indexes.js` | node | RDS CA pinned by checksum |
| payment, saga, notification | build → prod → migrate / runtime | `npx node-pg-migrate up --migrations-dir migrations --migration-file-language sql` | node | SQL migrations copied into `prod`; `node-pg-migrate` is a **runtime** dependency, so `npx` never downloads |
| frontend | build → runtime (nginx-unprivileged:1.29-alpine, port 8080) | — | nginx (non-root) | `ARG VITE_*` baked in; **the CSP `connect-src` is templated at build time** from the same URLs (a `node -e` replacement of `__CONNECT_SRC__` in nginx.conf), so the page may only call the APIs it was built for |

## 3. `.dockerignore` (what never enters the build context)
Auth's: `node_modules dist coverage tests keys src/generated docs events .env .env.* .git .github *.md`. Product's adds
`.venv __pycache__ *.pyc .pytest_cache .ruff_cache`. Why it matters:
- **Secrets:** `.env` and `keys/` (local JWT private keys) can't be copied into a layer by accident, even with `COPY . .` (frontend).
- **Correctness:** a host `node_modules` (macOS binaries) can't overwrite the Linux install.
- **Speed:** a smaller context means faster builds and better caching.

Note that auth excludes `events/`. That's correct, because Auth only publishes and never parses commands. The services that consume commands
explicitly `COPY events/schemas`.

## 4. Build args vs runtime env, again (with the frontend nuance)
Backends: **zero build args**. The same image runs in every environment, configured by env + secrets at start (Phase B §3).
Frontend: build args are unavoidable with Vite. Because production uses one origin, all `VITE_*_API_URL` = the shop origin, and the
SPA could be built once with relative URLs (Phase J-3 §3).

## 5. Standalone compose per repo (work on one service without the platform)
Each repo's `compose.yaml` starts **only its own dependencies**, on non-clashing host ports, with its own named volume:

| Repo | Host port |
|---|---|
| auth | Postgres 5441 + Mailpit 1025/8025 |
| product | Postgres 5442 |
| inventory | Postgres 5443 |
| order | Mongo 27018 |
| payment | Postgres 5445 |
| notification | Postgres 5446 + Mailpit 1025/8025 |
| saga | Postgres 5447 |

The shared stack (infrastructure `compose.yaml`) uses 5432/27017. So you can run a service's tests against its own DB while
the full stack is down. That suits an 8 GB machine: `docker compose up -d` in one repo, then `npm test`.

## 6. Commands, with what they do and their risks (recommendations; none were run)

| Command | Purpose | Notes |
|---|---|---|
| `docker buildx build --target runtime -t order:dev .` | Build one stage | `--target migrate` for the migration image; add `--platform linux/arm64` to mimic ECS (slow under emulation) |
| `docker build --progress=plain --no-cache .` | Debug a failing build step | `--no-cache` only when you suspect a stale layer |
| `docker history order:dev` | Layer sizes | find what bloats the image |
| `docker image inspect order:dev --format '{{.Config.User}} {{.Config.Cmd}}'` | Check the user and command | should print `node [node dist/server.js]` |
| `docker run --rm --env-file .env -p 4004:4004 order:dev` | Run the image alone | a quick smoke test: then `curl localhost:4004/health/live` |
| `docker run --rm --entrypoint sh -it order:dev` | Look inside | production containers can't be exec'd into (ECS `enable_execute_command=false`) |
| `docker compose --profile apps up -d --build <svc>` | Rebuild + restart one service | `--build` rebuilds its dependency chain too (local-development.md) |
| `docker compose logs -f --tail 100 <svc>` | Follow logs | pipe through `npx pino-pretty` for Node services |
| `docker compose exec <svc> sh` / `docker compose run --rm <svc>-migrate` | Shell in a running container / run a one-off job | `run` creates a new container from the service definition |
| `docker compose ps` / `docker inspect --format '{{json .State.Health}}' <container>` | Health status and the last health-check output | why a service is `unhealthy` |
| `docker system df` / `docker builder prune` | Disk use / clear the build cache | `no space left on device` fix |
| `docker compose down -v` | ⚠ **deletes volumes** (databases, Auth keys) | only for a deliberate reset |

## 7. Image security checklist (status)

| Item | Status |
|---|---|
| Non-root user | ✓ all images (node / 10001 / nginx-unprivileged); ECS also enforces `run_as` and rejects root (validation + negative test) |
| Read-only root FS in production | ✓ ECS (`/tmp` volume for writes) |
| No secrets in layers | ✓ (.dockerignore; secrets only at runtime) |
| Minimal runtime contents | ✓ multi-stage, `--omit=dev`; ◐ auth's **migrate** image still has the full Prisma CLI (S-5, accepted) |
| Exec-form CMD, signals reach the app | ✓ |
| Base images pinned by digest | ✗ tags only (`node:24-alpine`, `python:3.14-slim`, `nginx-unprivileged:1.29-alpine`): N-19 |
| Image vulnerability scan before push | ✗ in CI; ◐ ECR scan-on-push (no alarm): N-19 |
| Third-party downloads verified | ✓ RDS CA by SHA-256 |
| SBOM / provenance | ✗ N-19 |

## 8. What not to do (and how this repo avoids it)
- `COPY . .` before installing deps (kills caching): avoided, except in the frontend's build stage, where the manifests are copied first anyway.
- Running as root: avoided everywhere.
- Baking `.env` or keys into images: excluded by `.dockerignore`.
- Using `npm install` in Dockerfiles: `npm ci` everywhere.
- Migrations in the container entrypoint: separate `migrate` target (A-3, J-3).
- `latest` tags in production: images are tagged by git SHA, and ECR is immutable.
- Relying on `depends_on` alone for readiness: compose uses health/completion conditions, and services tolerate dependencies being late (A-3 §3).

## Exercises and acceptance criteria (Phase I)
1. Explain the layer-caching consequence of moving `COPY src ./src` above `RUN npm ci`.
2. Why does auth's runtime install use `--omit=optional --omit=peer --ignore-scripts`, and what would break without the pre-generated Prisma client?
3. Why must `CMD` use the exec form for graceful shutdown?
4. How does the frontend's CSP end up allowing exactly the API origins the bundle was built for?

**You're done with Phase I when** you can read any of the eight Dockerfiles stage by stage, explain each choice (caching, size,
user, signals, migrations, certificates), and choose the right Docker command to debug a build, a crash loop or an unhealthy container.
