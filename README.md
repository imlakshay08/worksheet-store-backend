# Worksheet Store — E-commerce Backend (Rails API)

Production Rails 7.1 API that powers a **live, revenue-generating** store selling
digital French worksheets — with **two payment rails** (Razorpay for India, PayPal
for international), **webhook-driven order fulfilment**, **secure expiring
downloads**, and a session-authenticated **admin panel**.

![Ruby](https://img.shields.io/badge/Ruby-3.1-CC342D?logo=ruby&logoColor=white)
![Rails](https://img.shields.io/badge/Rails-7.1_(API--only)-CC0000?logo=rubyonrails&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-Railway-4169E1?logo=postgresql&logoColor=white)
![Payments](https://img.shields.io/badge/Payments-Razorpay_%2B_PayPal-003087?logo=paypal&logoColor=white)
![Tests](https://img.shields.io/badge/tests-passing-brightgreen)

> 🌐 **Live:** the storefront at `frenchworksheethub.com` (a separate static app on
> GitHub Pages) consumes this API. This repository is the **backend + admin**.

---

## Why this project is interesting

It's a small codebase that solves the *hard* parts of real e-commerce correctly:
money can't be faked, downloads can't be stolen, fulfilment survives failures, and
prices are recorded immutably. Most of the value here is in the **engineering
decisions**, documented below.

---

## Architecture

A deliberately **decoupled** design: a static storefront and a stateless JSON API,
each deployed and scaled independently.

```
  Storefront (static, GitHub Pages)          Backend (this repo, Railway)
  ┌───────────────────────────────┐  HTTPS   ┌──────────────────────────────────┐
  │ HTML/CSS/JS + checkout modal   │ ───────► │ Rails 7.1 API (api_only)         │
  │ intl-tel-input, Razorpay/PayPal│  JSON    │  • Products / Orders endpoints    │
  └───────────────────────────────┘          │  • Payment order creation         │
                                              │  • Signature-verified webhooks    │
  Customer's inbox  ◄─── Resend email ─────── │  • Secure download tokens (R2)     │
                                              │  • Session-auth admin panel (ERB) │
  Cloudflare R2 (PDF storage) ◄───────────────│  • PostgreSQL (source of truth)   │
                                              └──────────────────────────────────┘
```

**Payment fulfilment is webhook-driven, not browser-driven** — the single most
important design choice (see below).

---

## Tech stack

| Layer | Choice |
|-------|--------|
| Language / framework | Ruby 3.1, **Rails 7.1 (`config.api_only`)** |
| Database | PostgreSQL |
| Payments | **Razorpay** (INR) + **PayPal Orders v2** (USD) |
| File storage | Active Storage → **Cloudflare R2** (S3-compatible) |
| Transactional email | **Resend** |
| Admin UI | Server-rendered ERB + Tailwind (CDN) |
| Abuse protection | **Rack::Attack** (throttling + body-size limits) |
| Hosting / CI | Railway (Docker), migrations run on deploy |
| Testing | Minitest |

---

## Key engineering decisions & trade-offs

**1. The webhook is the source of truth — the browser is not.**
An order is only marked paid and fulfilled inside the **signature-verified payment
webhook**, never from the client's success callback. A user cannot fake a purchase
by editing JS or replaying a request; closing the browser after paying still
fulfils the order server-to-server.

**2. Fulfilment is idempotent and failure-resilient.**
The webhook records the payment *first*, then delivers the download email **exactly
once** (tracked via `download_email_sent_at`). If email delivery raises, the action
returns `500` so the provider **retries** — and only the email step re-runs, because
the payment is already recorded. Replayed/duplicate webhooks are no-ops.

**3. Order amounts are snapshotted, never derived.**
Each order stores the exact `amount_cents` + `currency` **paid at checkout**. Editing
a product's price later never rewrites historical orders or revenue — essential for
accounting, receipts, and disputes. (This replaced an earlier design that recomputed
from the live product price — a subtle but real correctness bug.)

**4. Two currencies, one fulfilment path.**
Razorpay (INR) and PayPal (USD) are parallel rails that converge on the *same*
download-token + email logic. `payment_provider` + `currency` on the order drive
display and revenue, split by currency in the admin dashboard.

**5. Downloads are capability tokens, not guessable URLs.**
On payment, an order gets a `SecureRandom.urlsafe_base64(32)` token that is
**paid-gated, expiring (30 days), and download-count-capped (5)**. The endpoint
redirects to a **short-lived signed R2 URL** — the file itself is never public.
Refunds flip the order status and instantly revoke access.

**6. API-only, but sessions re-enabled for the admin.**
The app is `api_only` for a lean public API, with cookie/session/flash middleware
**manually re-added** so the server-rendered admin panel gets CSRF-protected,
`Secure`+`HttpOnly` session auth — without dragging full-stack middleware onto the
customer-facing JSON endpoints.

---

## Security

Hardened against the OWASP Top 10; highlights:

- **Payment integrity** — HMAC webhook signature verification (Razorpay + PayPal);
  server-controlled amounts (a buyer can't underpay); amount-mismatch logging.
- **Input validation** — allowlist strong params; model-level format + length caps
  on all customer input (validated at creation only, so internal updates never
  break); parameterized queries throughout (no SQL injection); output escaping.
- **Abuse / DoS** — Rack::Attack throttles on `/orders` and `/admin/login`
  (layered burst + sustained), plus request-body-size rejection before parsing.
- **Secrets** — all in Rails **encrypted credentials**; only the *public* payment
  key IDs ever reach the browser; PII filtered from logs.
- **Transport & sessions** — `force_ssl` (HSTS), `Secure`/`HttpOnly`/`SameSite=Lax`
  cookies, constant-time admin credential comparison.
- **Supply chain** — `bundler-audit` wired in for dependency CVE scanning.

---

## Domain model (core)

```
Product ──< Order
  Product: title, slug, price_in_paise (INR), price_in_cents (USD), worksheet_pdf
  Order:   customer details, payment_provider, currency, amount_cents (snapshot),
           status (pending → paid → refunded), download_token (+expiry, +count)
```

---

## Testing

Minitest coverage on the money-critical paths — webhook signature rejection
(missing/invalid → `400`), successful capture → paid + emailed, refund → download
revoked, and the admin "verify-with-provider & fulfil" reconciliation flow.

```bash
bin/rails test
```

---

## Local development

```bash
git clone <this-repo>
cd worksheet_store
bundle install

# Rails encrypted credentials are required (Razorpay/PayPal/R2/Resend keys).
# Provide your own master key + credentials to run against real services:
#   EDITOR="code --wait" bin/rails credentials:edit

bin/rails db:prepare      # create + migrate
bin/rails server
bin/rails test
```

Admin panel: `/admin/login` (single-user session auth).

---

## Deployment

Containerised (multi-stage `Dockerfile`) and deployed on **Railway**. The entrypoint
runs `db:prepare` on boot, so **migrations apply automatically on deploy**. Encrypted
credentials are decrypted in production via a single `RAILS_MASTER_KEY` env var — no
secrets in the image or repo.

---

## Roadmap

Next iteration (planned): migrate the storefront to **Next.js + Tailwind**, add
**customer accounts** (email/password + Google OAuth, Rails-owned JWT), a **cart**
with multi-item orders, and **order history / re-download**.

---

## Notes

Built as a real product for a working French tutor — a live store handling real
payments and customer data, not a toy demo. Design docs for the payment flow,
security posture, and full system topology live alongside this README in the repo.
