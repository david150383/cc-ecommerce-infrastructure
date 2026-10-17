# Phase L-4: Findings, Fix Order, Exercises, Acceptance Criteria

## 1. Findings (contracts and compatibility)

| ID | Priority | Finding | Status | Evidence | Fix | Effort |
|---|---|---|---|---|---|---|
| **L-F1** | P1 | **HTTP compatibility is checked in the wrong place and too late.** A service can remove or rename a response field, regenerate `openapi.json`, pass its own CI (the drift test only checks file == code) and deploy. `compat` runs only when someone later syncs into the contracts repo. Deployed clients (frontend, saga, payment, order) break at runtime | CONFIRMED (workflow + tests) | service `openapi.test.ts` drift tests; [sync-openapi.mjs](ecommerce-contracts/scripts/sync-openapi.mjs); no service CI runs `compat` | Each service's CI compares its generated OpenAPI with the **last published** one (a vendored copy of its own contract plus the `compat` lib, or an `oasdiff breaking` step) and fails on breaking changes without a new `/api/v2` | low–medium |
| **L-F2** | P1 (before the first v2) | **`messageVersion` isn't routable or dispatched**: not an SNS attribute, not in filter policies, not read by any consumer. The documented "emit v1 and v2 side by side" step would feed v2 to v1 consumers | CONFIRMED (code) | relays' `MessageAttributes` = `messageType` only; `filter_policy` on `messageType`; grep of all `src/` | Add the `messageVersion` attribute + filter-policy entries; consumers dispatch on (type, version) | medium |
| **L-F3** | P2 | Backend-to-backend HTTP contracts are unchecked (saga → order/payment, payment → order, order → product, auth → notification). Responses are cast, not parsed, so a rename fails with a `TypeError` | CONFIRMED (code) | [order-client.ts:79-80](ecommerce-saga-orchestrator/src/clients/order-client.ts#L79-L80) | Parse responses with Zod; vendor callee OpenAPI + assignability or schema-validation tests | low–medium |
| **L-F4** | P2 | "Safe" command changes can still break a rollout: strict owner parsers (`additionalProperties: false`) reject a new optional field sent by a sender that re-pinned first, so commands go to the DLQ. No deploy-order rule is documented | CONFIRMED (code + docs) | command parsers; [VERSIONING.md](ecommerce-contracts/VERSIONING.md) | Document "owner deploys first" for commands (and "server first" for requests); optionally allow unknown fields in owned commands | low |
| L-F5 | P2 | Published OpenAPI has no provenance: `sync-openapi` reads sibling **working trees** (any branch, e.g. unmerged `phase7`) and records no source commit | CONFIRMED | sync-openapi.mjs | Record `{repo, commit}` per document; sync only from tags or `main` | low |
| L-F6 | P2 | The contracts repo has **no remote**; vendoring works only on your machine. Pins can reference a branch (the lock checks hashes, not that `version` is a tag) | CONFIRMED | `git remote -v` empty; vendor.mjs accepts any ref | Push `cc-ecommerce-contracts`; `verify-contracts` asserts `git tag` exists for `version` (or the nightly E2E does) | low |
| L-F7 | P3 | `compat` ignores error responses, error codes and `security` requirements | CONFIRMED | [lib/compat.mjs:282-293](ecommerce-contracts/lib/compat.mjs#L282-L293) | Compare 4xx bodies, `code` enums, `security` | medium |
| L-F8 | P3 | Response conformance is runtime-tested only in Inventory; other services rely on compile-time typing of DTOs | CONFIRMED | [inventory openapi.spec.ts](ecommerce-inventory-service/test/openapi.spec.ts) | Copy Inventory's "real responses match the documented schemas" test | low |
| L-F9 | P3 | The released envelope `description` still says it is hand-copied into each repo | CONFIRMED | envelope.v1.schema.json line 5 | Patch release with the corrected description | low |
| L-F10 | P3 | No deprecation signals (`deprecated: true`, `Deprecation`/`Sunset` headers); `x-correlation-id` not declared | CONFIRMED | OpenAPI documents | Add when the first v2 appears | low |

## 2. What is strong (keep it)

- **Contract-first messages with ownership by folder**, enforced by tests; one envelope; examples that must validate.
- **Directional compatibility rules** ("judged from the side that didn't make it") that set the semver bump automatically.
  This is more principled than most tooling, and the demo branches show it working.
- **Vendoring from tags with SHA-256 locks** and a verifier in every service's tests: no silent drift, and each service
  upgrades deliberately.
- **Strict owners, tolerant readers**, and producers that test the messages their code actually emits.
- Consumer-driven checks without a broker: the saga's `RELIES_ON`, Notification running producers' examples through
  its real handler, and the frontend's compile-time `Assignable` checks.

## 3. Suggested fix order (when you choose to work on it)

1. L-F6 (push the contracts repo), then L-F1 (a breaking-change gate in each service's CI). Together these close the biggest
   real-world gap.
2. L-F3 (parse responses in backend clients), a small code change with a big diagnostic payoff.
3. L-F4 (write down the deploy-order rules in VERSIONING.md).
4. L-F2 before you ever ship a v2 message.
5. The P3s as you touch the areas.

## 4. Hands-on exercises (reading; the optional ones are offline and change no repo)

1. **Classify by hand**, then check against §2 of L-3: (a) add optional `warehouseId` to `InventoryReserved`; (b) make
   `RefundRequested.payload.reason` accept a new value `FRAUD`; (c) add `FRAUD` to the `reason` of `RefundSucceeded`
   (if it had one); (d) change `amountMinor` from `integer` to `number` in an API response; (e) add a required query
   parameter to `GET /api/v1/orders`. Which need major, which minor, which are warnings?
2. **Trace a re-pin**: for the saga moving from v1.2.0 to v1.3.0, list which files `vendor.mjs` would rewrite (hint: v1.3.0
   changed only inventory OpenAPI, which the saga doesn't vendor) and what `contracts.lock.json` fields change.
3. **Break it on paper:** using [order-client.ts](ecommerce-saga-orchestrator/src/clients/order-client.ts), describe exactly
   what happens, state by state, if Order renamed `totals` to `summary`. Then write (outside the repos) the Zod schema the
   client should parse with.
4. **Design L-F2:** write the new filter policy JSON for `notification-inbox--order-events` during a migration where
   Notification reads `OrderConfirmed` v2 but the saga still reads v1.
5. *(Optional, offline; read-only git)* in `ecommerce-contracts`: `git diff v1.0.0 v1.1.0 -- openapi/payment-service.openapi.json`
   and explain why the change was a **minor**.
6. Read [docs/breaking-change-demo.md](ecommerce-contracts/docs/breaking-change-demo.md) and explain why the saga's tests
   passed on the rename branch while Notification's failed.

## 5. Interview-style questions

- *Why does a command belong to its consumer and an event to its producer?* A command is a request to the receiver's
  capability (its API), so the receiver decides what it accepts. An event is a fact the producer publishes, so the producer
  decides what it says, and readers adapt.
- *Adding a required field: when is it safe?* In an event payload or API response it's safe (readers ignore extras). In a
  command or request it's breaking, because existing senders don't send it.
- *Why can a "safe" change still cause an outage?* Compatibility is about shapes; rollouts are about order. A strict
  receiver that hasn't deployed yet rejects a field a sender already sends (L-F4).
- *What's the difference between the drift test and the compat check?* Drift: "is the committed contract what the code
  generates?" Compat: "does the new contract break whoever didn't change?" You need both, ideally in the producer's CI.
- *Why vendor contracts instead of fetching them at build time?* Reproducible builds, no network dependency, and
  deliberate, reviewable upgrades per consumer.

## 6. Phase L summary

**Topics covered:** contract concepts; contract-first messages vs code-first HTTP; the envelope; command vs event
ownership; runtime validation (strict owners, tolerant readers); consumer-driven checks; vendoring and locks;
OpenAPI generation per stack and drift tests; frontend type checks; backend client gaps; compat rules and version bumps;
expand → migrate → contract for messages, HTTP and databases; deploy-order rules; AsyncAPI; blind spots.

**Files examined:** contracts `README.md`, `VERSIONING.md`, `CHANGELOG.md`, `docs/OWNERSHIP.md`,
`docs/breaking-change-demo.md`, `lib/{catalog,compat,services}.mjs`, `scripts/{compat,vendor,sync-openapi,import-from-services,build}.mjs`,
test names, envelope + RefundRequested + InventoryReserved schemas, the AsyncAPI header; services' `openapi/document.ts`
(order, auth, payment), product `export_openapi.py`, inventory `configure-app.ts` + `openapi.spec.ts`, notification
`parsers.ts` + `consumer-contracts.test.ts`, saga `event-schemas.test.ts` + `order-client.ts`, order `outbound-clients.test.ts`;
contract-related test names across services; `git log`/tags of contracts and the demo branches.

**Commands executed (read-only):** `cat`, `sed`, `grep`, `git log`, `node -e` to read JSON. **No** test, `compat`,
`vendor` or `sync` run.

**Unresolved questions:** Do you want the breaking-change gate for HTTP (L-F1) implemented with the project's own `compat`
library (vendored into services) or with a standard tool like `oasdiff`? Will you push `cc-ecommerce-contracts` soon (it
unblocks L-F1, L-F6 and the nightly E2E)?

## 7. Acceptance criteria for Phase L

- You can explain why messages are contract-first and HTTP APIs code-first, and the risk each choice carries.
- You can classify any schema change as breaking / warning / safe with its direction, and state the required bump.
- You can describe the full expand → migrate → contract sequence for an event, a command, an HTTP field and a DB column,
  including **who deploys first**.
- You can explain L-F1, L-F2 and L-F4 with file and line, and how you'd verify a fix.
- You can walk through `vendor.mjs` and `verify-contracts.mjs` and say what each protects against.

Next options: **Phase M** (integration testing, observability, troubleshooting, production readiness), **Phase N** (the
consolidated, prioritized backlog across all phases), or **Phase B** to go back in order.
