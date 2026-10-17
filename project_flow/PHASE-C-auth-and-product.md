# Phase C: Authentication Service and Product Service

Read-only walkthrough of `ecommerce-auth-service` (Express 5 + Prisma 7 + jose) and `ecommerce-product-service`
(FastAPI + SQLAlchemy 2 + PyJWT). File and line references are on the `phase7` branch.

---

## Part 1: Auth Service

### 1.1 What it is and why it exists
Auth is the platform's **identity provider**. It owns users, passwords, sessions and refresh tokens, and signs
**access tokens (JWT, RS256)** that every other service verifies **locally** with its public keys (JWKS). Nothing calls Auth
per request. It also runs the OAuth2 **client-credentials** grant for service-to-service calls.

### 1.2 Request pipeline ([app.ts:55-89](ecommerce-auth-service/src/app.ts#L55-L89))

```
trust proxy (TRUST_PROXY_HOPS) → helmet → cors(origins, credentials) → requestContext (correlation id)
→ pino-http → express.json({limit: 100kb}) → cookieParser → /health/* → /.well-known/jwks.json
→ /openapi.json, /docs → /api/v1/auth/* → /api/v1/admin/* → /internal/v1/auth/* → 404 → errorHandler (problem+json)
```
Express 5 forwards rejected promises from async handlers to the error handler. That's why handlers simply `throw new HttpProblem(...)`.

### 1.3 Data model ([schema.prisma](ecommerce-auth-service/prisma/schema.prisma))
`User` (email unique, `CHECK email = lower(btrim(email))` added in raw SQL: [migration](ecommerce-auth-service/prisma/migrations/20261013161005_email_normalized_check/migration.sql)),
`Session` (absolute expiry, revokedAt/reason), `RefreshToken` (**hash only**, usedAt, expiry), `EmailVerificationToken`,
`PasswordResetToken` (hash only), `AuthAuditLog`, `OutboxMessage` (`outbox` table).

Why tokens are stored as SHA-256 hashes ([random-token.ts](ecommerce-auth-service/src/security/random-token.ts)): a
database leak yields no usable token. A *fast* hash is fine because the input is 256 random bits, not a human password.

### 1.4 Flows, traced

| Flow | Route → service | Key mechanics |
|---|---|---|
| **Register** | `POST /api/v1/auth/register` (per-IP limit) → [auth.service.ts:109-154](ecommerce-auth-service/src/modules/auth/auth.service.ts#L109-L154) | Zod normalizes email (trim + lowercase) before validating; policy: 12–128 chars, small denylist, must not contain the email's local part; **Argon2id** hash (m=19 MiB, t=2, p=1); **one transaction**: user + verification token hash + `UserRegistered` outbox row + audit; unique violation → 409; verification email sent **after** commit (failure logged, not fatal) |
| **Login** | `POST /login` (per-IP **and** per-account failure limiter) → [:158-188](ecommerce-auth-service/src/modules/auth/auth.service.ts#L158-L188) | Unknown email → verify against a **dummy hash** (same time cost, so no enumeration by timing); same 401 for unknown/wrong; "suspended" revealed only after a correct password; TX: session (absolute 30 d) + refresh token (idle 7 d, capped at session expiry) + audit |
| **Tokens returned** | [auth.routes.ts:30-40](ecommerce-auth-service/src/modules/auth/auth.routes.ts#L30-L40), [cookies.ts](ecommerce-auth-service/src/modules/auth/cookies.ts) | Body: `accessToken` (15 min), `csrfToken`, `user`. Cookies: `refresh_token` **HttpOnly, Secure, SameSite=Strict, Path=/api/v1/auth**; `csrf_token` readable (Path=/). `Cache-Control: no-store` |
| **Refresh** | `POST /refresh` with `requireCsrf` → [:196-233](ecommerce-auth-service/src/modules/auth/auth.service.ts#L196-L233) | Lookup by hash → **reuse check** (`usedAt` set → revoke the whole session) → inside TX: `updateMany({id, usedAt: null})` as an **atomic claim**: if two requests race, exactly one gets `count = 1`, and the other is treated as reuse. `handleReuse` deliberately uses `db`, **not** `tx`, so the revocation survives the rollback |
| **Logout** | `POST /logout` (CSRF) | idempotent; revokes the session; clears cookies |
| **Logout all** | `POST /logout-all` (Bearer) | revokes every session of the user |
| **Verify email** | `POST /verify-email` | idempotent (already verified → 200); claim via conditional update; `UserEmailVerified` event |
| **Forgot password** | `POST /forgot-password` → `setImmediate(...)` | **always 202, and the work runs after the response**, so neither the status nor the timing reveals whether the account exists; previous links invalidated; the secret link is sent via the Notification Service's internal endpoint (never a queue) |
| **Reset password** | `POST /reset-password` | claim the token; new Argon2id hash; **revoke all sessions** |
| **Service token** | `POST /internal/v1/auth/service-token` ([service-token.ts](ecommerce-auth-service/src/modules/internal/service-token.ts)) | clientId + secret checked by **constant-time compare of SHA-256 hashes** (a fixed dummy hash for unknown clients); `audience` must be in the client's allowlist; token `{sub: clientId, roles: ["service"], aud: <target>}`, 300 s; audited |
| **Admin** | `GET /api/v1/admin/users`, `PATCH …/{id}/status` | admin role; can't change own status; **suspending revokes all sessions** in the same TX |

### 1.5 Keys and JWKS ([key-store.ts](ecommerce-auth-service/src/security/key-store.ts), [token-service.ts](ecommerce-auth-service/src/security/token-service.ts))
- Keys come from `JWT_SIGNING_KEYS` (JSON from Secrets Manager) or `JWT_KEYS_DIR` (local; a key is generated on first dev
  start). The kid format is `YYYYMMDD-<random>`, so **sorting by kid = sorting by age**. The **newest signs**, and all are published.
- Rotation without downtime: add a newer kid → deploy → verifiers pick it up after their JWKS cache expires (Product: 10 min) →
  remove the old key after the access-token TTL.
- Verification pins `algorithms: ["RS256"]`, issuer, audience, and 30 s clock tolerance. This defeats the classic
  "`alg: none`" / HS256-with-public-key attacks.

### 1.6 CSRF and cookies: why this design
The refresh token sits in an HttpOnly cookie (JavaScript, including XSS, can't read it). Cookies are sent automatically,
which is what CSRF exploits. Defenses: `SameSite=Strict` (cross-site requests carry no cookie), plus a **double-submit**
token. A forged request can't read the `csrf_token` cookie to copy it into `X-CSRF-Token`
([csrf.ts](ecommerce-auth-service/src/middleware/csrf.ts), constant-time compare). The access token lives in **memory only**
in the SPA, never in localStorage (Phase H), and the E2E test asserts there's no JWT in web storage.

### 1.7 Rate limiting ([rate-limit.ts](ecommerce-auth-service/src/middleware/rate-limit.ts))
Per IP: 30/min on unauthenticated endpoints. Per account: 5 **failed** logins per 15 min (`skipSuccessfulRequests`, keyed by
the normalized email). The counters are **in memory** (per task, reset on deploy), so the WAF provides the shared limit. That's why
K-F1 (WAF bypass) matters. `req.ip` is correct only with the right `TRUST_PROXY_HOPS` (2 in AWS).

### 1.8 Alternatives and trade-offs

| Choice | Alternative | When the alternative wins |
|---|---|---|
| Self-hosted auth | Cognito, Auth0, Keycloak | when you need SSO/social login/MFA quickly; when you don't want to own password storage |
| Stateless JWT (15 min) + rotating refresh | opaque session ids checked on every request | when immediate revocation is mandatory (here a revoked user keeps access ≤ 15 min) |
| RS256 + JWKS | HS256 shared secret | never across services: every verifier could also *mint* tokens |
| Argon2id | bcrypt, scrypt | bcrypt is fine but has a 72-byte limit; Argon2id is the OWASP first choice |
| Cookie refresh + in-memory access token | everything in localStorage | never: XSS steals it |

### 1.9 What not to do (and what the code avoids)
Logging tokens (redaction + tests); different errors for unknown vs wrong password (same 401); storing raw tokens
(hashes); `alg` from the token header (pinned); refresh tokens without rotation/reuse detection; secrets in queues
(transactional mail is synchronous HTTP).

### 1.10 Observations for the backlog (small, new)
- **Registration reveals existing emails** (409 `EMAIL_ALREADY_REGISTERED`). Login and forgot-password avoid enumeration,
  register doesn't. That's a common, accepted trade-off. The alternative is "check your inbox" for both cases plus an email to
  the existing owner (P3, N-32).
- **Login doesn't require a verified email** (`emailVerifiedAt` isn't checked in login or checkout). That's a product decision.
  If a verified email should be required before buying, enforce it in the saga's checkout route (P3).
- A suspended or reset user keeps working **access** tokens up to 15 min (stateless JWT; documented in N-32).

### 1.11 Tests that prove it ([tests/](ecommerce-auth-service/tests))
`register-login` (incl. "writes a schema-valid UserRegistered event to the outbox in the same transaction"), `tokens`
(rotation, reuse revokes), `email-password` (verify/reset, tokens never in logs), `hardening`, `service-token`, `admin`,
`messaging` (relay publishes once, schema-valid), `event-schemas`, `env`.

---

## Part 2: Product Service

### 2.1 What it is and why it exists
The catalog: categories (a tree), products, variants (= SKUs) with prices, images, specifications, and search. It's the
**source of truth for current prices**. Order asks it at checkout time and snapshots the answer.

### 2.2 App assembly ([main.py](ecommerce-product-service/app/main.py))
`create_app(settings, readiness_checks, engine=…, token_verifier=…)` builds the app **without starting a server**. Tests
inject a scratch DB engine and test keys. Middleware (Starlette runs it in reverse registration order): RequestContext
(correlation, request log) → CORS → security headers. Routers: products, categories, internal. Errors →
problem+json ([errors.py](ecommerce-product-service/app/errors.py)). Uvicorn drains on SIGTERM; `lifespan` flips readiness and disposes the engine.

### 2.3 Data model ([models.py](ecommerce-product-service/app/models.py))
- `Category`: unique slug (regex CHECK), `parent_id` (RESTRICT), CHECK "not own parent"; the tree is read with a **recursive CTE** (`_descendant_ids`).
- `Product`: slug, status `DRAFT | PUBLISHED | ARCHIVED` with CHECK "published ⇒ published_at", `version` (optimistic
  concurrency), **generated `search_vector`** (`Computed(...)` tsvector) with a GIN index, plus a `pg_trgm` GIN index on `name`.
- `Variant`: unique SKU (regex CHECK), ISO currency CHECK, `price_minor >= 0` (BigInteger), optional sale price with window
  and CHECKs, `attributes` JSONB, `is_active`.

### 2.4 Key logic

| Concern | Code | How |
|---|---|---|
| **Effective price, in one place, twice** | [pricing.py](ecommerce-product-service/app/pricing.py) | `effective_price_minor()` in Python and `sql_effective_price()` as a SQL `CASE` encode the **same** rule (a sale applies only inside its window); tests run both on the same rows. List pages sort/filter by price in SQL, the detail page in Python, and they can't disagree |
| **Search** | [catalog.py:181-250](ecommerce-product-service/app/catalog.py#L181-L250) | `websearch_to_tsquery('english', q)` on the generated tsvector **OR** `pg_trgm` word similarity (`<%`) on the name, so typos and word starts ("cott") match. Rank = `ts_rank + word_similarity`. `SET LOCAL pg_trgm.word_similarity_threshold` uses a module **constant**, never user input |
| Listing | same | price aggregate over **active** variants; public callers see only `PUBLISHED`; filtering by status is admin-only (403); `sort=relevance` requires `q`; page size ≤ 100 |
| **Concurrent edits** | [routers/products.py](ecommerce-product-service/app/routers/products.py) | GET returns `ETag: "<version>"`; PATCH **accepts** `If-Match` (optional: without it the last write wins); a mismatch → **412 `VERSION_MISMATCH`** ([catalog.py:361-364](ecommerce-product-service/app/catalog.py#L361-L364)). Any change (even child-only) bumps the version. The admin UI does send it ([admin.ts:138-140](ecommerce-frontend/src/api/admin.ts#L138-L140), tested in `admin.test.tsx`) |
| Publishing rules | `_set_status`, `update_variant` | a published product must keep ≥ 1 active variant (409 `PRODUCT_NOT_PUBLISHABLE`); all variants share one currency (422) |
| Delete | `archive_product` | **soft delete** (ARCHIVED): orders and inventory keep referencing its SKUs |
| **Internal price lookup** | [catalog.py:463-490](ecommerce-product-service/app/catalog.py#L463-L490), [routers/internal.py](ecommerce-product-service/app/routers/internal.py) | `POST /internal/v1/products/price-lookup` (role `service`): only **active variants of PUBLISHED products**; returns `items` (name, ids, effective unit price) and `unavailable` SKUs, in request order, deduplicated |

### 2.5 Security ([security.py](ecommerce-product-service/app/security.py))
`PyJWKClient(url, cache_keys=True, lifespan=600)` caches JWKS for 10 min. `jwt.decode(algorithms=["RS256"], issuer,
audience=[ecommerce-api, ecommerce-product-service], leeway=30, require=[exp, iat, sub, iss, aud])`. Auth unreachable with no cached
key → **503** (our problem, not the client's), invalid → 401. `optional_principal`: anonymous browsing is allowed, but a **bad**
token is still rejected (it doesn't silently become anonymous). `AdminPrincipal`, `ServicePrincipal` are role dependencies.

### 2.6 Alternatives and trade-offs
- Postgres full-text + trigram vs OpenSearch/Algolia: Postgres is enough up to a large catalog and avoids a second store to keep
  in sync. A dedicated search engine wins for facets, synonyms, typo tolerance at scale, and analytics.
- Synchronous price lookup vs a price **event** stream into Order: sync gives the exact price at order time with no replica to
  maintain; the cost is availability coupling (Product down → no new orders).
- Sync SQLAlchemy in FastAPI (threadpool) vs async SQLAlchemy: sync is simpler and fine at this load; async helps at very high concurrency.

### 2.7 Observations (new, small)
- **Catalog ↔ stock are linked only by SKU strings, by hand.** Creating a product/variant doesn't create an Inventory
  `stock_items` row (Product publishes no events). An admin must stock the SKU in Inventory separately, or checkout fails with
  `UNKNOWN_SKU`. An optional `VariantCreated` event consumed by Inventory (creating `on_hand = 0`) would remove the manual step (P3).
- Product publishes no `PriceChanged`/`ProductArchived` events (fine today, since Order queries synchronously).

### 2.8 Tests ([tests/](ecommerce-product-service/tests))
`test_products` (CRUD, search incl. "the trigram index can serve the query", ETag concurrency, publishing rules),
`test_categories` (tree, restrict delete), `test_internal_and_pricing` (Python vs SQL price rule agreement, lookup),
`test_security` (alg pinning, audiences, 503 on JWKS outage), `test_openapi` (drift), `test_app`.

## Exercises and acceptance criteria (Phase C)
1. Trace two concurrent `POST /refresh` calls with the same cookie through [auth.service.ts:196-233](ecommerce-auth-service/src/modules/auth/auth.service.ts#L196-L233): which returns tokens, which revokes the session, and why the revocation isn't rolled back?
2. Explain why `forgot-password` uses `setImmediate` and what an attacker could learn without it.
3. Explain how Product guarantees list prices and detail prices agree, and what would break if only the Python rule existed.
4. Write the steps to rotate the JWT signing key without logging anyone out.

**You're done with Phase C when** you can draw the token lifecycle (login → access + refresh → rotation → reuse
detection → logout), explain each cookie attribute, and trace a product search from the query string to SQL.
