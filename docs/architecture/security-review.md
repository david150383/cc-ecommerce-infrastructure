# Security review (Phase 7)

Date: 2026-10-15. Scope: the ten repositories at their `phase7` branches, the local stack, and the AWS design
(`deployment.md`). Method: automated scans (with each scanner first shown to detect a planted problem), code
review against the platform's threat model, and tests added for every fix. Nothing was deployed to AWS.

## Threat model (summary)

| Asset | Threats | Main controls |
|---|---|---|
| Customer accounts | credential stuffing, session theft, CSRF, account enumeration | Argon2id (19 MiB, t=2), per-account + per-IP limits (service) and **WAF per-IP limits (edge)**, refresh rotation with reuse detection, HttpOnly/Secure/SameSite=Strict cookies + double-submit CSRF, identical answers for unknown accounts |
| Money | tampered amounts, forged payment confirmations, double charges/refunds | amounts only from the Order Service, signed webhooks (raw body, 5-min window, dedupe), idempotency keys end to end, refunds bounded by paid − refunded − pending |
| Stock | reserving without paying (inventory hoarding) | **max 3 active checkouts per customer** (new), reservation expiry, WAF |
| Secrets (signing keys, DB, Stripe, SMTP) | leaks in git, logs, events, Terraform state | per-service Secrets Manager secrets (values never in Terraform), RDS-managed master passwords, log redaction, secret-bearing mail never stored/queued, gitleaks over full history |
| Service-to-service APIs | calls from the internet, confused deputy | `/internal/*` blocked at the ALB, service tokens with per-target audience, command parsers accept only commands addressed to them |
| Infrastructure | direct origin access, privilege escalation in CI | ALB reachable from CloudFront only, private subnets, no public IPs, no exec into containers, read-only root FS, non-root; OIDC deploy roles per repository + GitHub environment |

## Automated checks (all re-runnable)

| Check | Result | Evidence |
|---|---|---|
| Secrets in the full git history of all 10 repos (gitleaks 8.28, Docker) | **No real secret.** 12 false positives (lock-file hashes, a PEM placeholder in a comment, the common-password denylist, hashes of local-only client secrets) triaged one by one and allowlisted narrowly in `.gitleaks.toml` | Scanner proven on a planted AWS key + Stripe live key; the allowlist still catches a planted Stripe key in `compose.yaml`. The only `BEGIN PRIVATE KEY` in any history is the placeholder |
| Production dependencies (`npm audit --omit=dev`, 8 Node repos) | 7 repos clean; Auth: 4 high via the Prisma CLI (`mysql2`, `deepmerge-ts`) | Runtime image inspected: none of the packages present. Present only in the one-off migrate image (see S-5) |
| SQL built by string interpolation (TypeScript, Python) | None with user input | 2 interpolations: a WHERE built from fixed `$n` fragments (notification paging) and Prisma's parameterised tagged `$queryRaw`; no `*Unsafe` raw APIs; Product uses the ORM only |
| Personal data in logs | None found | Log calls mention ids, never e-mail/phone values; SMS adapter logs masked numbers; tests assert reset/verification tokens never reach logs |
| Workflow security (actionlint 1.7.7 + shellcheck) | All 10 repositories clean | Linter proven on a broken workflow |
| Infrastructure guarantees (`terraform test`, mocked provider) | 8 module suites pass | network, platform, data, service, frontend, github-oidc, waf, stack; mutation-checked (disabling rollback / enabling public IPs fails the suite) |

## Findings

| ID | Severity | Finding | Status |
|---|---|---|---|
| S-1 | **High** | No limit on concurrent checkouts: one account could reserve the whole inventory for 30 min per checkout without paying | **Fixed**: saga refuses a new checkout with 429 `TOO_MANY_ACTIVE_CHECKOUTS` beyond `MAX_ACTIVE_CHECKOUTS_PER_CUSTOMER` (3); advisory lock makes it race-free (mutation-checked); UI explains it. WAF limits add a per-IP layer |
| S-2 | Medium | Service rate limits (`express-rate-limit`) are in memory: N tasks = N× the attempts, reset on every deploy | **Fixed in the design**: WAF web ACL on CloudFront (auth 100 / 5 min / IP, API 3000 / 5 min / IP, AWS common + known-bad-inputs + IP-reputation rules). In-service limits stay as a second layer |
| S-3 | Medium | An ALB open to 0.0.0.0/0 would let clients bypass CloudFront (and the WAF) | **Fixed in the design**: ALB ingress only from CloudFront's managed prefix list (tested) |
| S-4 | Medium | Distribution-wide CloudFront error responses would turn API 404s into `index.html` with 200 | **Fixed in the design**: viewer-request function on the SPA behavior only (tested) |
| S-5 | Low | The migrate image (Prisma CLI) contains `mysql2` and `deepmerge-ts` with high advisories | **Accepted**: short-lived job, no external input, PostgreSQL only (`mysql2` never loaded); npm's "fix" is a downgrade to Prisma 6. Revisit when Prisma 8 is stable |
| S-6 | Medium | Command parsers accepted any command whose schema was present, including commands meant for other services | **Fixed** (Phase 6) and tested |
| S-7 | Medium | Auth could not load signing keys on ECS (no persistent disk) | **Fixed**: `JWT_SIGNING_KEYS` from Secrets Manager, validated at startup |
| S-8 | Low | Base images are referenced by tag (`node:24-alpine`), not digest; no automated dependency updates | **Open**: pin digests and enable Renovate/Dependabot once the repositories are on GitHub |
| S-9 | Low | CI does not fail on new vulnerable dependencies | **Open**: add `npm audit --omit=dev --audit-level=high` (with an allowlist for S-5) to service CI; ECR scan-on-push is configured, but its findings do not alarm yet |
| S-10 | Low | Product search cost (the original note said `ILIKE`; it was full text with a GIN index) | **Fixed**: full text plus `pg_trgm` word similarity, both index-backed (`ix_products_search_vector`, `ix_products_name_trgm`; a test proves the trigram index can serve the query); WAF rate limits still apply |
| S-11 | Medium | A paid order cancelled by its customer stops at `CANCELLATION_PENDING` (no refund/close flow) | **Fixed**: the saga refunds, closes the order as `REFUNDED` and returns the stock (`verify-order-cancellation.py`); a failed refund goes to manual review and the customer is emailed |
| S-12 | Low | Order Service on DocumentDB is untested (developed against MongoDB 8) | **Reduced**: TLS with the pinned RDS CA bundle, `retryWrites=false` enforced at startup, operators limited to a DocumentDB 5.0 allowlist (test). **Still open**: run the Order test suite against a real DocumentDB before the first production deploy |
| S-13 | Low | `sprintf-js` ≤1.1.3 (GHSA-hp3w-g68c-fv3c, DoS) in Inventory's test-coverage tooling (istanbul → js-yaml 3 → argparse 1); no patched version exists | **Accepted**: dev-only, never shipped, no untrusted input. CI fails only on high/critical in production dependencies |
| S-14 | — | Dependency advisories | **Gate added**: `npm audit --omit=dev --audit-level=high` in every Node repo's CI, `pip-audit` in Product's. Auth's 4 high advisories via the Prisma CLI fixed with overrides (`deepmerge-ts` 8.0.2, `mysql2` 3.24.5) |

## Verified controls (tests that would fail if they regressed)

- Auth: refresh-token reuse revokes the session; reset/verification tokens removed from URLs and never logged
  or stored by the Notification Service (database + log scans in tests); same response for unknown accounts.
- Authorization: customers get 404 for other customers' orders, payments, checkouts and notifications; admin
  routes require the admin role; service tokens are audience-bound.
- Payments: forged, tampered, replayed and duplicate webhooks; amounts never from the client; refunds bounded.
- Frontend: payment redirect only to allowlisted origins (mutation-checked); success only from the saga status;
  no tokens in web storage; strict CSP (`connect-src 'self'` in production).
- Infrastructure: see the module tests listed above.
