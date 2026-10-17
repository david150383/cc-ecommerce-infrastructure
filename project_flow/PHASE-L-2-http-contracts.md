# Phase L-2: HTTP Contracts: OpenAPI per Service, Drift Tests, Clients, Versioning

## 1. How each service produces its OpenAPI (code-first)

| Service | Generator | Spec version | Source of the schemas | Drift test |
|---|---|---|---|---|
| auth, order, payment, saga, notification | `@asteasolutions/zod-to-openapi` (`OpenApiGeneratorV31`) in `src/openapi/document.ts` | 3.1.0 | **the same Zod schemas** that validate requests (e.g. `CreateOrderRequest`, `OrderResponse` in [order.schemas.ts](ecommerce-order-service/src/orders/order.schemas.ts)) | `openapi.test.ts`: committed `openapi/openapi.json` == `buildOpenApiDocument()` |
| product | FastAPI `create_app(settings).openapi()` from routes + Pydantic models ([export_openapi.py](ecommerce-product-service/app/export_openapi.py)) | 3.1.0 | Pydantic models | `tests/test_openapi.py` |
| inventory | `@nestjs/swagger` `DocumentBuilder` + decorators ([configure-app.ts](ecommerce-inventory-service/src/configure-app.ts)) | **3.0.0** | DTO classes / decorators | `openapi.spec.ts` drift **plus "real responses match the documented schemas"** (Ajv against actual HTTP responses) |

What the drift test proves: **the committed file equals what the code generates**. It forces you to commit the regenerated
file (`npm run openapi:export` / `python -m app.export_openapi`). What it **doesn't** prove:
- that the change is **compatible** (it happily accepts a removed field; L-F1);
- that real responses match the document. Requests are validated by the same Zod schemas, so they're safe. Responses are
  built by DTO functions such as `toOrderDto(o): OrderDtoT`, which are typed from the Zod schema (a compile-time match), but
  formats, enums and nullability aren't checked at runtime. Only Inventory validates real responses against its OpenAPI;
  that's the pattern to copy.

**3.0 vs 3.1:** OpenAPI 3.1 is fully JSON Schema 2020-12 (`type: ["string","null"]`); 3.0 uses `nullable: true`. `compat`
normalizes both ([lib/compat.mjs:32-46](ecommerce-contracts/lib/compat.mjs#L32-L46)), and `openapi-typescript` handles both.

## 2. Publishing: [scripts/sync-openapi.mjs](ecommerce-contracts/scripts/sync-openapi.mjs)

```bash
# inside ecommerce-contracts
npm run sync:openapi        # reads ../<repo>/openapi/openapi.json for all 7 services
npm run compat              # judge the result against the last tag
npm version minor && git push --follow-tags   # release (once a remote exists)
```

The script copies from the **working trees** of sibling repos, whatever branch is checked out (here `phase7`, which is
unmerged). The published document therefore has **no provenance**: nothing records which service commit it came from, or
whether that commit is deployed. Recording `{repo, commit}` per OpenAPI file (as the lock file does for consumers) would
close that gap. Today the contracts repo could publish an API that no environment serves yet (P2, L-F5).

## 3. Clients of the HTTP APIs and how (or whether) they're checked

| Client → API | Operation used | Contract check | Status |
|---|---|---|---|
| Frontend → every public API | many | Generated types from **pinned** OpenAPI (`openapi-typescript`) + 16 `Assignable<Published, UiReads>` assertions in [contract-check.ts](ecommerce-frontend/src/api/contract-check.ts) + CI `git diff --exit-code src/api/generated` | ✓ checked at re-pin time (compile time) |
| Saga → Order `POST /api/v1/orders` | reads `order.id`, `order.totals.grandTotal.{amountMinor,currency}` | hand-written cast `json as {order: {...}}` ([order-client.ts:79-80](ecommerce-saga-orchestrator/src/clients/order-client.ts#L79-L80)); tests use stubs | ✗ unchecked |
| Saga → Payment `POST /api/v1/payments/intent` | `payment.id`, `checkoutUrl` | same pattern | ✗ |
| Payment → Order `GET /internal/v1/orders/{id}` | amount, status, customer | same pattern | ✗ |
| Order → Product `POST /internal/v1/products/price-lookup` | prices, availability | stubbed client tests ([outbound-clients.test.ts](ecommerce-order-service/tests/outbound-clients.test.ts)) | ✗ |
| Auth → Notification `POST /internal/v1/notifications/transactional` | 2xx/4xx | — | ✗ |
| All services → Auth JWKS / service-token | standard formats | token tests | partial |

**Finding L-F3 (CONFIRMED):** backend-to-backend HTTP contracts are not checked anywhere except the nightly E2E, which
can't run yet (J-F5/J-F12). Example failure: Order renames `totals.grandTotal`. Order's CI is green (the drift test just
updates the file). The saga's `o.totals.grandTotal.amountMinor` throws `TypeError` → `runSyncStep` logs "synchronous
step crashed" → treated as `dependency-failed` → retries → `FAILED` for **every checkout**.
Cheap fixes, in order: (1) the saga **parses** responses with Zod (fail clearly, not with a TypeError); (2) backends vendor
the OpenAPI documents of the APIs they call (like the frontend) and add `Assignable` checks or schema validation in their
client tests; (3) the producer's CI runs `compat` for its own OpenAPI (L-F1).

## 4. API versioning in practice

- Every public path is `/api/v1/...`, internal ones `/internal/v1/...`. The convention for breaking changes is a `/api/v2/...`
  path **beside** v1 with a deprecation window (VERSIONING.md). No v2 exists yet.
- No `Deprecation` / `Sunset` headers or deprecation markers (`deprecated: true` in OpenAPI) are used. Add them when the
  first v2 appears, so clients see the window in the contract and at runtime.
- **Errors** are RFC 9457 `application/problem+json` with a stable `code` (e.g. `IDEMPOTENCY_KEY_REUSED`). The frontend's
  user messages key on `code`, so **error codes are part of the contract**. But `compat` compares only **2xx** responses
  ([lib/compat.mjs:282-293](ecommerce-contracts/lib/compat.mjs#L282-L293)), so renaming or removing an error code is
  invisible to it. Documented error codes appear in the OpenAPI response **descriptions** (text), not as an enum. An enum
  on `code` per operation would make them checkable (P3).
- **Security** requirements per operation (bearer, roles) aren't compared either. An endpoint that starts requiring the
  `admin` role breaks clients without any compat finding.

## 5. Idempotency and correlation headers as contract

`Idempotency-Key` is declared as a required request header on mutating operations (e.g. `IdempotencyHeader` in Order's
document). `compat` compares header parameters except `authorization`, so "now requires `Idempotency-Key`" would be reported as
breaking. `x-correlation-id` is a convention (conventions.md) and isn't declared in the OpenAPI documents. Declaring it as
an optional header would make it visible to clients.
