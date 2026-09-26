# Worksheet Store — E-commerce Backend (Rails API)

Production Rails 7.1 API powering a **live, revenue-generating** store that sells
digital French worksheets — **two payment rails** (Razorpay for India, PayPal for
international), a **multi-item cart**, **webhook-driven fulfilment**, **per-worksheet
expiring download tokens**, a session-authenticated **admin panel**, and a **SerpApi-backed
market-intelligence page** that tells the owner which worksheet to build next.

![Ruby](https://img.shields.io/badge/Ruby-3.1.4-CC342D?logo=ruby&logoColor=white)
![Rails](https://img.shields.io/badge/Rails-7.1_(API--only)-CC0000?logo=rubyonrails&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-Railway-4169E1?logo=postgresql&logoColor=white)
![Payments](https://img.shields.io/badge/Payments-Razorpay_%2B_PayPal-003087?logo=paypal&logoColor=white)
![Storage](https://img.shields.io/badge/Storage-Cloudflare_R2-F38020?logo=cloudflare&logoColor=white)
![Search data](https://img.shields.io/badge/Search_data-SerpApi-3B82F6)
![Tests](https://img.shields.io/badge/Minitest-53_tests-brightgreen)

> 🌐 **Live:** the storefront at `frenchworksheethub.com` (a separate static app on
> GitHub Pages) consumes this API. This repository is the **backend + admin**.

---

## Why this project is interesting

It's a small codebase that solves the *hard* parts of real e-commerce correctly:
money can't be faked, downloads can't be stolen, fulfilment survives failures,
prices are recorded immutably, and a live schema migration didn't break a single
download link already sitting in a customer's inbox. Most of the value here is in
the **engineering decisions**, documented below and in [ARCHITECTURE.md](ARCHITECTURE.md).

Not a tutorial project — a real store, with real customers, real money, and real
consequences for getting it wrong.

---

## Architecture

A deliberately **decoupled** design: a static storefront and a stateless JSON API,
each deployed and scaled independently.

```
  Storefront (static, GitHub Pages)          Backend (this repo, Railway)
  ┌────────────────────────────────┐  HTTPS  ┌───────────────────────────────────┐
  │ HTML/CSS/JS, localStorage cart │ ──────► │ Rails 7.1 API (api_only)          │
  │ checkout modal, intl-tel-input │  JSON   │  • Products / Orders endpoints     │
  │ Razorpay Checkout + PayPal SDK │         │  • Payment order creation          │
  └────────────────────────────────┘         │  • Signature-verified webhooks     │
                                             │  • Per-item download tokens        │
  Customer's inbox ◄── Resend email ──────── │  • Session-auth admin panel (ERB)  │
                                             │  • PostgreSQL (source of truth)    │
  Cloudflare R2 (PDF storage) ◄───────────── │                                    │
                                             │  • Research page (read-only) ──────┼──► SerpApi
                                             └───────────────────────────────────┘
```

**Payment fulfilment is webhook-driven, not browser-driven** — the single most
important design choice (see below).

---

## Tech stack

| Layer | Choice |
|-------|--------|
| Language / framework | Ruby 3.1.4, **Rails 7.1.6 (`config.api_only`)** |
| Database | PostgreSQL |
| Payments | **Razorpay** (INR) + **PayPal Orders v2** (USD, hand-rolled `Net::HTTP` client) |
| File storage | Active Storage → **Cloudflare R2** (S3-compatible) |
| Transactional email | **Resend** (branded HTML + plain-text) |
| Market data | **SerpApi** — Google Search + Google Shopping, hand-rolled `Net::HTTP` client, responses cached in Postgres |
| Admin UI | Server-rendered ERB + Tailwind (CDN), mobile-responsive |
| Media pipeline | Ghostscript (PDF compression), ImageMagick (preview images), `pdf-reader` (page counts) |
| Abuse protection | **Rack::Attack** (layered throttles + body-size blocklist) |
| Hosting / CI | Railway (multi-stage Docker), migrations run on deploy |
| Testing | Minitest, 53 tests on the money-critical paths (+ the isolated research feature) |

---

## Key engineering decisions & trade-offs

**1. The webhook is the source of truth — the browser is not.**
An order is only marked paid and fulfilled inside the **signature-verified payment
webhook**, never from the client's success callback. A user cannot fake a purchase
by editing JS or replaying a request; closing the browser after paying still fulfils
the order server-to-server. The PayPal `onApprove` capture endpoint exists purely as
a latency optimisation and is idempotent against the webhook.

**2. Fulfilment is idempotent and failure-resilient.**
The webhook records the payment *first*, then delivers the download email **exactly
once** (guarded by `download_email_sent_at`). If email delivery raises, the action
returns `500` so the provider **retries** — and only the email step re-runs, because
the payment is already recorded. Replayed or duplicate webhooks are no-ops.

**3. Money is snapshotted, never derived.**
Each order stores the exact `amount_cents` + `currency` **paid at checkout**, and each
line item stores its own `unit_amount_cents`. Editing a product's price later never
rewrites historical orders or revenue — essential for accounting, receipts, and
disputes. (This replaced an earlier design that recomputed from the live product
price: a subtle but real correctness bug.)

**4. A live cart migration that broke zero existing download links.**
Moving from one-product-per-order to a multi-item cart meant the download lookup had
to move from `Order` to a new `OrderItem`. Links already emailed to customers embed a
token — so the migration **backfills one line item per existing order, copying the
exact token string, expiry, and download count**, then relaxes `orders.product_id` to
nullable. Additive only, no row rewrites, safe to auto-run on deploy. Every link ever
sent still resolves. See [`20260718120000_create_order_items.rb`](db/migrate/20260718120000_create_order_items.rb).

**5. Downloads are capability tokens, not guessable URLs.**
Each purchased worksheet gets its own `SecureRandom.urlsafe_base64(32)` token that is
**paid-gated, expiring (30 days), and download-count-capped (5)**. The endpoint
redirects to a **short-lived signed R2 URL** — the file itself is never public.
Refunds flip the parent order's status and instantly revoke every link on it.

**6. Two currencies, one fulfilment path.**
Razorpay (INR, paise) and PayPal (USD, cents) are parallel rails that converge on the
*same* token + email logic. `payment_provider` + `currency` on the order drive display
and revenue, split by currency on the admin dashboard so the two are never conflated.

**7. API-only, but sessions re-enabled for the admin.**
The app is `api_only` for a lean public API, with cookie/session/flash middleware
**manually re-added** so the server-rendered admin panel gets CSRF-protected,
`Secure`+`HttpOnly` session auth — without dragging full-stack middleware onto the
customer-facing JSON endpoints.

**8. Soft delete that frees storage but preserves the books.**
"Removing" a worksheet purges its files from R2 (reclaiming paid storage) but keeps
the record if it has ever sold, so revenue and order history stay intact. Never sold?
The row is deleted outright. The download endpoint degrades gracefully to a friendly
message if a customer opens a link to a file that's been purged.

**9. Uploads are optimised, but optimisation can never break an upload.**
Canva-exported PDFs are huge, so uploads are piped through Ghostscript (and preview
images through ImageMagick). Both shell-outs are wrapped so that a timeout, a missing
binary, a crash, or a result that isn't actually smaller all fall back to the original
file untouched — and are skipped entirely on the Windows dev box.

**10. A new feature next to live payments earns its keep by not touching them.**
The Research page (below) is read-only *by contract*: it writes nothing but its own cache
rows, and on the sales side it reads a `COUNT` — never an amount, a token, or a status.
Nothing it can do — a bad API key, an exhausted quota, a SerpApi outage — has any path to
the money. Its tests assert that boundary rather than just its happy path.

---

## Market intelligence (SerpApi)

A tutor's hardest question isn't "how do I sell this?" — it's **"what should I make next?"**
`/admin/market_intelligence` answers it by joining public search data to private business
data, which is the one thing an off-the-shelf SEO tool structurally cannot do.

**The demand gap — the headline.** Google supplies the demand side; this store's own
database supplies the supply side. Subtract one from the other and you get a decision:

| | people search for it | nobody searches for it |
|---|---|---|
| **you've sold it** | **Proven** — make more like this | **Selling** — quiet but real |
| **you haven't sold it** | **Wanted, not selling** — the listing is the problem, not the product | no signal yet |
| **you don't have it** | **the gap — make this next** | — |

**Where the demand comes from matters.** Google increasingly answers a query with an AI
Overview instead of "People also ask" and "Related searches" — for this store's own
keywords, those blocks come back *empty*. So demand is mined from two engines that still
return real user queries: **`google_autocomplete`** for the long tail, already ordered by
popularity, and **`google_trends`** related queries, which is the only source that attaches
**relative volume** (0–100, or "Breakout"). Both feed one weighted score, so the ranking
reflects how much a thing is wanted rather than how often a word appears.

Demand phrases are clustered by **topic, not by string**: "french verb conjugation
worksheet pdf" and "how do you practise french verb conjugation" are one want in two
phrasings, and a more specific phrasing folds into the general topic it belongs to.
Coverage is decided on meaningful words only, so a product titled "Verb Conjugation Drills"
is recognised as already covering that search.

Two filters keep the list actionable. Trends **drifts** — seed it with "french grammar" and
it offers "french toast near me" and "how to learn calligraphy" — so a phrase must actually
be about French. And demand for an *app*, a *course*, a *tutor near me* or a *translator* is
real but isn't demand for a worksheet, so it's dropped too. Searches wanting it **free** are
kept but flagged: real demand, bad customers for a paid store.

The supply side reads a `COUNT` of paid line items per product across **both** payment
rails (the modern cart and legacy single-product orders) — units only, never amounts, so
nothing here can misreport revenue.

**Supporting cards:**
- **Worksheet idea finder** — type a rough topic and get back Google's `related_questions`
  and `related_searches`: the exact phrasings learners use. Each one links into the
  new-worksheet form, pre-filled — a real search query becomes a drafted product in one click.
- **Rank tracking** — where `frenchworksheethub.com` sits in `organic_results` for a
  configurable keyword list, with the top 5 competitors for each.
- **Competitor pricing** — Google Shopping results for comparable worksheets with a
  **median** listed price (median, not mean, so one mispriced bundle can't skew it).

**The interesting constraint is quota, not integration.** The free SerpApi tier is a small
monthly search budget, so *loading the page never spends a search*: every card renders from
a `serp_snapshots` cache table, and only a **POST-only Refresh button** spends any. There
are two of them — *Refresh demand* and *Refresh ranks & prices*, 6 searches each — so
re-checking demand never re-spends the ranking budget, and each button is labelled with its
exact cost. POST-only is load-bearing: a reload, a bookmark, or a crawler can never burn the
budget. Stale rows are shown labelled "stale" rather than silently refetched, and because
rows are append-only, rank movement over time comes for free.

Because analysis runs over the cache rather than the API, the scoring and filtering above
were tuned by re-running against **already-paid-for** data — the whole tuning loop cost zero
additional searches.

SerpApi also reports quota exhaustion in an `error` key with an **HTTP 200**, so the client
validates the body as well as the status code, and never echoes the request URI into an
error (it carries the key).

---

## Security

Reviewed against the OWASP Top 10; highlights:

- **Payment integrity** — HMAC webhook signature verification (Razorpay) and PayPal's
  `verify-webhook-signature` API; amounts are set server-side from the snapshot (a
  buyer can't underpay); amount mismatches are logged loudly.
- **Input validation** — allowlist strong params; model-level format + length caps on
  all customer input (validated `on: :create`, so internal status updates are never
  blocked by legacy data); parameterized queries throughout; output escaping in both
  the admin and the emails.
- **Abuse / DoS** — Rack::Attack throttles `/orders` (15 per 10 min per IP) and
  `/admin/login` (layered 5/20 s burst + 20/10 min sustained), plus a >16 KB
  request-body blocklist that rejects before Rails parses. Webhooks are safelisted.
- **Secrets** — all in Rails **encrypted credentials**; only the *public* payment key
  IDs ever reach the browser; customer PII filtered from request logs.
- **Transport & sessions** — `force_ssl` (HSTS), `Secure`/`HttpOnly`/`SameSite=Lax`
  cookies, constant-time admin credential comparison, `reset_session` on login.
- **File safety** — content-type + size validation on both attachments; a memory guard
  that skips PDF page-counting above 15 MB so a large upload can't OOM the instance.
- **Supply chain** — `bundler-audit` wired in for dependency CVE scanning.

---

## Domain model

```
Product ──< OrderItem >── Order
  Product:   title, slug, level, page_count, price_in_paise (INR),
             price_in_cents (USD), removed_at, worksheet_pdf + preview_image (R2)
  Order:     customer details, payment_provider, currency,
             amount_cents (snapshot), status (pending → paid → refunded)
  OrderItem: unit_amount_cents (snapshot), download_token (+expiry, +count)
```

`orders.product_id` is retained but nullable — legacy single-item orders keep it;
new code reads `order_items`.

`serp_snapshots` (query, engine, jsonb payload, fetched_at) sits outside this graph
entirely — no association, no join, nothing in the purchase flow reads it.

---

## Public API

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/products` | Active worksheets as JSON (title, level, slug, ₹ + $ price, page count, preview URL) |
| `GET`  | `/products/:slug/preview` | Page-1 preview image — the *curated* image, never the paid PDF |
| `POST` | `/orders` | Create a pending order from a cart, snapshot prices, open a Razorpay or PayPal order |
| `GET`  | `/orders/:id` | Lightweight status poll |
| `POST` | `/orders/:id/paypal_capture` | Server-side capture from PayPal's `onApprove` (idempotent) |
| `POST` | `/webhooks/razorpay` | Signature-verified fulfilment / refund / failure events |
| `POST` | `/webhooks/paypal` | Signature-verified fulfilment / refund events |
| `GET`  | `/download/:token` | Redirect to a signed, short-lived R2 URL for one worksheet |

---

## Testing

Minitest with fixtures and threaded parallelisation, focused on the paths where a bug
costs money or leaks a paid file rather than on coverage percentage:

- **Downloads** — valid token redirects and counts; unknown token, unpaid parent order,
  refunded order, and exhausted download limit all `404`.
- **Orders** — missing customer fields rejected; unknown/inactive product `404`;
  multi-item cart snapshots the summed total; duplicate worksheets de-duplicated;
  legacy single-`product_slug` payloads still work; PayPal cart rejected when a
  worksheet has no international price.
- **Webhooks** — missing signature `400`, invalid signature `400`, valid capture marks
  paid *and* emails, refund revokes downloads.
- **Admin** — auth guards on every page, and the Razorpay reconciliation path both
  when the provider confirms payment and when it doesn't.
- **Research** — the auth guard on Refresh (a signed-out POST spends no search), the page
  rendering with no key and an empty cache, exactly one live call per topic search with
  nothing cached, a SerpApi failure surfacing as a message rather than a 500, and the
  client's error paths (non-2xx, an `error` inside a 200 body, timeouts). `Net::HTTP` is
  stubbed throughout — the suite never reaches serpapi.com or spends quota.
- **Demand gap** — uncovered demand ranked and clustered, a specific phrasing folding into
  its general topic, a covered phrase excluded from the gap list, off-topic and wrong-product
  demand dropped, free-intent flagging, the four catalogue verdicts, and paid units counted
  across both the cart and legacy orders while an unpaid order is ignored.
- **Scoped refresh** — refreshing demand calls autocomplete and Trends once per seed each
  (with Trends' `data_type`) and spends **no** SERP or Shopping searches, and vice versa.

```bash
bin/rails test
```

---

## Local development

```bash
git clone <this-repo>
cd worksheet_store
bundle install

# Rails encrypted credentials are required (Razorpay/PayPal/R2/Resend/admin keys).
# Provide your own master key + credentials to run against real services:
#   EDITOR="code --wait" bin/rails credentials:edit

bin/rails db:prepare      # create + migrate
bin/rails server
bin/rails test
```

Admin panel: `/admin/login` (single-user session auth; `/` redirects there).
Active Storage uses local disk in development and R2 in production, so no cloud
credentials are needed just to click around.

To try the Research page, add a [free SerpApi key](https://serpapi.com/) to credentials:

```yaml
serpapi:
  api_key: your_key_here
```

Without it the page still renders and says so — the feature is inert, never broken.

---

## Deployment

Containerised (multi-stage `Dockerfile`, non-root runtime user) and deployed on
**Railway**. The entrypoint runs `db:prepare` on boot, so **migrations apply
automatically on deploy** — which is why every migration in this repo is written to be
additive and safe against live data. Encrypted credentials are decrypted in production
from a single `RAILS_MASTER_KEY` env var; no secrets in the image or the repo.

The storefront (`french-tuiton-website/`) is its own git repo deployed to GitHub Pages.
Backend and storefront ship independently — push the backend first when they change
together.

---

## Roadmap

Shipped so far: the multi-item cart (July 2026) and the SerpApi research page with its
demand-gap analysis (September 2026).

Candidates for the next iteration, in rough order of how much correctness they buy:
a **background job queue** for email (durability currently comes from webhook retries),
**upgrading off EOL Ruby 3.1**, **customer accounts + order history / re-download**, and
a storefront rebuild on **Next.js + Tailwind**. None of these are committed — the store
works, and each is a real cost against a business that currently runs fine without it.

---

## Notes

Built as a real product for a working French tutor: a live store handling real payments
and customer data, not a toy demo. [ARCHITECTURE.md](ARCHITECTURE.md) is the full
end-to-end system reference — hand it to any developer or assistant for complete context
without questions.
