# French Worksheet Hub — Complete Architecture Reference

_Last updated: 17 September 2026 (reflects the `order_items` cart refactor, product
soft-delete + storage reclaim, preview images, the upload optimisation pipeline, and the
read-only Market Intelligence admin page backed by SerpApi)._

_This is the single source of truth for how the whole system works, end to end.
Hand this to any developer or assistant to get full context without questions._

---

## 1. What this is

A small e-commerce system that sells **digital French worksheets (PDFs)**. A customer
adds one or more worksheets to a cart, pays online, and immediately receives a
download link **per worksheet** by email. The owner (Nidhi Tyagi) manages worksheets
and views orders through an admin panel.

**Two separately-deployed halves:**

| Half | What | Tech | Hosted on |
|------|------|------|-----------|
| **Storefront** | Public marketing + cart + checkout | Static HTML/CSS/JS | GitHub Pages (`frenchworksheethub.com`) |
| **Backend** | JSON API + admin panel + payment/webhook/email/download logic | Rails 7.1 (API-only) + Postgres | Railway |

The storefront calls the backend's JSON API cross-origin. The admin panel is
server-rendered HTML served by the same Rails app.

**External services:** **Razorpay** (India, INR, live) + **PayPal** (international,
USD, live), **Resend** (email), **Cloudflare R2** (file storage, S3-compatible),
**SerpApi** (Google search data for the admin-only Research page, §8),
GitHub Pages (storefront host), Railway (backend + Postgres host).

---

## 2. Tech stack & gems

Ruby 3.1.4, Rails 7.1.6, PostgreSQL, Puma.

**Gems (`Gemfile`):**
- `pg` — Postgres
- `puma` — web server
- `aws-sdk-s3` (`require: false`) — Active Storage backend for Cloudflare R2
- `razorpay` — Razorpay SDK. PayPal has **no gem** — it's a hand-rolled `Net::HTTP`
  client (see §12); the official Ruby SDK is deprecated.
- `resend` — transactional email API
- **SerpApi has no gem either** — like PayPal it's a hand-rolled `Net::HTTP` service
  object (`app/services/serp_api_client.rb`); it's one GET request with query params.
- `pdf-reader` — pure-Ruby PDF page counting (no system dependency)
- `rack-cors` — CORS for the cross-origin storefront
- `rack-attack` — rate limiting / throttling / body-size limits
- `tzinfo-data`, `bootsnap`, `i18n`
- dev/test: `debug`, `error_highlight`, **`bundler-audit`** (dependency CVE scan)
- **`bcrypt` is present but commented out** — admin auth deliberately does NOT use it
  (see §8).

**System binaries (installed in the production image):** `ghostscript` (PDF
compression), `imagemagick` (preview-image processing), `libvips`, `postgresql-client`.

**Frontend (CDN, no build step):** Tailwind (admin only), intl-tel-input (phone
field), Razorpay Checkout.js + PayPal JS SDK (storefront), Google Fonts.

---

## 3. Repository layout

```
worksheet_store/
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb        # ActionController::API (public API base)
│   │   ├── products_controller.rb           # public: GET /products, /products/:slug/preview
│   │   ├── orders_controller.rb             # public: create / show / paypal_capture
│   │   ├── webhooks_controller.rb           # public: POST /webhooks/{razorpay,paypal}
│   │   ├── downloads_controller.rb          # public: GET /download/:token
│   │   └── admin/
│   │       ├── base_controller.rb           # ActionController::Base + session auth + rescue_from
│   │       ├── sessions_controller.rb       # login/logout
│   │       ├── dashboard_controller.rb      # revenue / orders / storage stats
│   │       ├── products_controller.rb       # worksheet CRUD + remove + upload optimisation
│   │       ├── orders_controller.rb         # orders list/detail/resend/fulfill
│   │       └── market_intelligence_controller.rb  # READ-ONLY SerpApi research page
│   ├── models/
│   │   ├── product.rb, order.rb, order_item.rb
│   │   ├── serp_snapshot.rb                 # cached SerpApi responses (not commerce)
│   │   └── concerns/download_link_host.rb   # host resolution for emailed links
│   ├── services/
│   │   ├── paypal_client.rb                 # PayPal Orders v2 + webhook verify (Net::HTTP)
│   │   ├── serp_api_client.rb               # SerpApi search (Net::HTTP, same pattern)
│   │   └── demand_gap_analyzer.rb           # search demand x catalogue x paid sales
│   └── views/
│       ├── layouts/{admin,admin_auth}.html.erb
│       └── admin/{sessions,dashboard,products,orders,market_intelligence}/*.html.erb
├── config/
│   ├── application.rb                       # api_only + manual sessions + IST time zone
│   ├── routes.rb
│   ├── environments/production.rb           # force_ssl, R2, STDOUT logging
│   ├── credentials.yml.enc                  # all secrets (encrypted)
│   ├── storage.yml                          # R2 service definition
│   └── initializers/{cors,rack_attack,filter_parameter_logging,razorpay,resend}.rb
├── db/{schema.rb, migrate/*}
├── db/seeds.rb                               # demo catalogue/sales + captured SerpApi data
├── test/                                    # Minitest, 59 tests
├── french-tuiton-website/                   # the STOREFRONT (SEPARATE git repo → GitHub Pages)
│   ├── index/shop/about/contact.html + terms/privacy/refund/shipping.html
│   ├── style.css, script.js, CNAME, favicons
│   └── products.js                          # legacy static product list; no longer loaded
├── Dockerfile, bin/docker-entrypoint        # Railway deploy
├── README.md                                # public repo landing page
├── ARCHITECTURE.md                          # this file
├── PAYMENTS_ROADMAP.md, ECOMMERCE_UPGRADE_PLAN.md, PAYPAL_SETUP.md
```

> The storefront folder is its **own git repository** (deploys to GitHub Pages),
> nested inside the backend repo for convenience. Two repos, two deploys.

---

## 4. Data model

### `products`
| Column | Type | Notes |
|--------|------|-------|
| title | string | ≤150 chars |
| description | text | plain text; the storefront formats bullets/headings |
| level | string | e.g. "A2–B1" (CEFR tag) |
| **price_in_paise** | integer | INR price in paise (₹1 = 100 paise) |
| **price_in_cents** | integer | USD price in cents; **nil = not sold internationally** |
| slug | string | URL-safe; auto-generated from the title, never rewritten once set |
| active | boolean | only active products are listed/sellable |
| page_count | integer | cached from the PDF via `pdf-reader` |
| **removed_at** | datetime (indexed) | NULL = live; timestamp = soft-removed |
| timestamps | | |

Active Storage attachments: `worksheet_pdf` (the paid PDF) and `preview_image` (a
public page-1 teaser). Both live in R2.

### `orders`
| Column | Type | Notes |
|--------|------|-------|
| email, name, phone | string | customer contact (collected at checkout) |
| address_line, city, state, postal_code, country | string | customer address |
| **product_id** | bigint (FK, **nullable**) | legacy single-item orders only; new orders use `order_items` |
| **payment_provider** | string | `"razorpay"` or `"paypal"` |
| **currency** | string | `"INR"` or `"USD"` |
| **amount_cents** | integer | **snapshot** of the exact total paid (minor units) |
| status | string | `"pending"` → `"paid"` → optionally `"refunded"` |
| razorpay_order_id, razorpay_payment_id | string | Razorpay rail |
| paypal_order_id (indexed), paypal_capture_id | string | PayPal rail |
| download_email_sent_at | datetime | one-time email delivery guard |
| download_token, download_token_expires_at, download_count | | **legacy**, superseded by `order_items` |
| timestamps | | |

### `order_items`
| Column | Type | Notes |
|--------|------|-------|
| order_id, product_id | bigint (FK) | one line per purchased worksheet |
| **unit_amount_cents** | integer | snapshot of that worksheet's price in the order's currency |
| **download_token** | string (unique index) | `SecureRandom.urlsafe_base64(32)` |
| download_token_expires_at | datetime | 30 days from issue |
| download_count | integer | default 0, capped at 5 |
| timestamps | | |

A cart is a **set of distinct worksheets — no quantities**. A PDF is something you own
or you don't, so duplicates are de-duplicated at order creation.

### `Product` model
- `has_one_attached :worksheet_pdf`, `has_one_attached :preview_image`.
- `has_many :orders` and `has_many :order_items`, both `dependent: :restrict_with_error`.
- `scope :listed` → `where(removed_at: nil)`. **Deliberately not a `default_scope`** —
  `order_item.product` must still resolve a removed product for order history.
- `price_in_rupees` / `price_in_usd` accessors convert the paise/cents columns to and
  from the plain values the admin types (`7900 ↔ 79`, `499 ↔ 4.99`). `usd_amount_string`
  formats cents as `"4.99"` for PayPal.
- `ensure_slug` auto-generates a unique slug from the title on create, and **never
  rewrites an existing slug** (that would break live buy links).
- **Validations:** title/slug presence + length; slug format `[a-z0-9-]` + uniqueness;
  description ≤8000; `worksheet_pdf` must be a **PDF ≤ 40 MB**; `preview_image` must be
  an image ≤ 5 MB.
- `refresh_page_count!` counts pages with `pdf-reader`, **skipped above 15 MB**
  (`PAGE_COUNT_MAX_BYTES`) because the pure-Ruby reader can spike memory enough to get
  the process OOM-killed on a small instance. Any error is logged and swallowed.
- `sold?`, `stored_bytes`, `purge_files!`, `removed?` back the admin remove flow (§8).

### `Order` model
- Constants: `DOWNLOAD_LIMIT = 5`, `DOWNLOAD_VALID_FOR = 30.days` — the single source
  of truth, also used by `OrderItem`.
- Scopes: `paid`, `pending`, `refunded`. `paypal?` helper.
- **Amount is SNAPSHOTTED, not derived.** `amount_cents` + `currency` are frozen at
  checkout. `display_amount` formats them (₹ or $). **Never recompute from the
  product's current price.** `expected_amount_minor` (Razorpay, integer paise) and
  `expected_amount_decimal_string` (PayPal, `"4.99"`) give the expected charge for
  webhook amount verification.
- **Customer-input validations** (`on: :create`, `allow_blank`): email format + ≤150;
  name ≤100; phone format `[0-9+\-()\s]` + ≤30; address field length caps. Scoped to
  creation so internal status updates (e.g. a webhook marking an order paid) are never
  blocked by slightly-off legacy data.
- `worksheet_titles` / `worksheets_summary` — admin display, falling back to the legacy
  `product` association for any pre-migration order without items.
- `mark_refunded!` sets status `"refunded"`, which revokes **every** item's download.
- `deliver_download_email!` — ensures a token per item, sends one Resend email listing
  all of them, then stamps `download_email_sent_at`. **Raises on failure** so callers
  (webhook / admin) can react.

### `OrderItem` model
- `download_available?` — true only if the **parent order** is `"paid"` AND a token is
  present AND it hasn't expired AND `download_count < DOWNLOAD_LIMIT`.
- `ensure_download_token!` — generates token + 30-day expiry once, idempotently.
- `display_amount`, `download_url` (built via the `DownloadLinkHost` concern).

### `DownloadLinkHost` concern
Resolves the host for emailed links: `ENV["APP_HOST"]` → `ENV["RAILWAY_PUBLIC_DOMAIN"]`
→ `localhost:3000`. The Railway fallback exists so a missing/forgotten env var can
**never** ship a dead `localhost` link to a real paying customer.

### `serp_snapshots` (not part of the commerce domain)
A standalone cache table for the admin Research page (§8). It has **no association to
any other table** — nothing joins to it, and nothing in the purchase flow reads it.

| Column | Type | Notes |
|--------|------|-------|
| query | string | the search term, e.g. `"french worksheets pdf"` |
| engine | string | SerpApi engine id — `"google"` or `"google_shopping"` |
| payload | jsonb | the **trimmed** response (see below) |
| fetched_at | datetime | when the search was actually spent |
| timestamps | | |

Indexed on `[query, engine, fetched_at]` — the only lookup is "newest row for this
search". Rows are **append-only history**, never updated, so rank movement over time is
visible for free.

### `SerpSnapshot` model
- `FRESH_FOR = 12.hours`; `fresh?`, `.fresh_for(query:, engine:)` → newest *fresh* row,
  `.latest_for(...)` → newest row **at any age** (the page shows a stale rank labelled
  "stale" rather than spending a search to avoid an empty cell).
- `.record!` writes a row with `fetched_at: Time.current`.
- The controller **trims** the payload to `organic_results`, `related_questions`,
  `related_searches`, `shopping_results` before storing. Full SerpApi responses are
  large, and the dropped keys (`search_parameters`, `search_metadata`) are the ones
  carrying request details we don't want sitting in the database.

---

## 5. The `order_items` migration (why it matters)

`db/migrate/20260718120000_create_order_items.rb` moved the store from
one-product-per-order to a cart, against a **live database with real customers holding
emailed download links**. It runs automatically on deploy, so it had to be safe:

1. Create an empty `order_items` table.
2. `change_column_null :orders, :product_id, true` — relaxes a constraint only; never
   rewrites a row.
3. Backfill one line item per existing order in raw SQL (independent of model code,
   which has already moved on), copying the product, the amount, and — critically —
   the **exact `download_token` string, expiry, and count**.

Because the download lookup moved from `Order` to `OrderItem` but the token *value* was
carried across verbatim, every link already sitting in a customer's inbox kept working.
The backfill is guarded by `NOT EXISTS`, so re-running is a no-op. The `down` migration
deliberately does *not* restore the `NOT NULL`, since multi-item orders legitimately
have a null `product_id` by then.

---

## 6. Backend — controllers & the public API

All public controllers inherit `ApplicationController < ActionController::API`.

### `GET /products` → `ProductsController#index`
JSON array of **active** products: `{ title, description, level, slug, price (₹),
price_usd, page_count, preview_url }`. `level` and `page_count` are read through
`has_attribute?` guards so the storefront keeps working even if this code deploys
before its migration has run.

### `GET /products/:slug/preview` → `ProductsController#preview`
Streams the admin-curated page-1 preview image inline with a 1-hour public cache
header. **Never** the worksheet PDF, which stays payment-gated. 404 if absent.

### `POST /orders` → `OrdersController#create`
1. Reads the cart: `items: [{slug}]` or `items: ["slug"]`, **or** the legacy
   `product_slug` (kept so an older cached storefront keeps working). De-duplicated.
2. Loads those slugs as `active: true` products, preserving cart order. Any missing
   slug ⇒ the cart is stale ⇒ `404` with a "please refresh" message.
3. Strong-params the customer fields (allowlist); requires `name`, `email`, `phone`
   (`422` if missing); model validations reject malformed/oversized input (`422`).
4. Picks the rail from `params[:provider]` (`"paypal"` or default `"razorpay"`) and the
   currency from it (`USD` / `INR`). PayPal carts where any worksheet lacks a USD price
   are rejected (`422`).
5. **Snapshots** each worksheet's price *now* into an `OrderItem`, sums them into
   `order.amount_cents`, saves the order as `pending`.
6. Creates the provider order:
   - **razorpay** → `Razorpay::Order.create` for `amount_cents`; returns
     `razorpay_order_id`, the **public** `razorpay_key_id`, `amount`, `product_title`.
   - **paypal** → PayPal Orders v2 create; returns `paypal_order_id`. Provider failures
     return `502` with a friendly message.

### `POST /orders/:id/paypal_capture` → `OrdersController#paypal_capture`
Called from the PayPal button's `onApprove`. Captures the approved order server-side,
verifies `status == "COMPLETED"`, logs any amount mismatch, then fulfils. Already-paid
orders short-circuit. This is a client-triggered **convenience for latency**; the
webhook remains the source of truth and will fulfil idempotently if this call is lost.

### `GET /orders/:id` → `OrdersController#show`
Returns `{ status, product_title }` for lightweight polling.

### `POST /webhooks/razorpay` → `WebhooksController#razorpay`
CSRF-exempt; signature-authenticated. Missing signature → `400`; HMAC verified over
`request.raw_post` with `razorpay.webhook_secret`, invalid → `400` (rescuing Ruby's
**`SecurityError`**, which the gem raises — there is no
`Razorpay::SignatureVerificationError`). Dispatches:
- **`payment.captured`** → record the payment first (`status: paid`,
  `razorpay_payment_id`), then deliver the email **exactly once**. Amount mismatch vs
  the snapshot is logged.
- **`refund.created` / `refund.processed`** → `mark_refunded!` (revokes all downloads).
- **`payment.failed`** → logged; the order stays pending so the buyer can retry.

### `POST /webhooks/paypal` → `WebhooksController#paypal`
Verifies via **PayPal's `verify-webhook-signature` API** (transmission headers +
`webhook_id`); invalid → `400`. Dispatches:
- **`PAYMENT.CAPTURE.COMPLETED`** → same record-then-email-once fulfilment. The order is
  matched by the capture's `custom_id` (our order id), falling back to
  `supplementary_data.related_ids.order_id`.
- **`PAYMENT.CAPTURE.REFUNDED` / `.REVERSED`** → `mark_refunded!`, matching the order via
  the refund's `up` HATEOAS link to its parent capture.

**The ordering is the point:** payment is persisted before the email is attempted. If
email raises, the action 500s, the provider retries, and only the email step re-runs —
the money is never lost, and the customer is never emailed twice.

### `GET /download/:token` → `DownloadsController#show`
Looks up the **`OrderItem`** by token. Unavailable (unknown / unpaid / refunded /
expired / limit reached) → `404` with a human-readable message. If the product's file
has since been purged → a distinct, friendly `404`. Otherwise increments
`download_count` and redirects to Active Storage's **signed, short-lived R2 URL**.
(`ActiveStorage::Current.url_options` is set from the request so the local Disk service
works in dev; R2 returns absolute presigned URLs and ignores it.)

---

## 7. The complete purchase flow (end to end)

```
[Storefront]  renderProducts() → GET /products → cards.
              "Add to cart" → localStorage cart (distinct slugs, badge, cart modal)
              "Checkout" → checkout MODAL (name/email/phone via intl-tel-input,
              address/city/state/postal/country). The ₹/$ rail is auto-selected
              from the buyer's detected country.

  ── Razorpay (India, ₹) ──                  ── PayPal (international, $) ──
  POST /orders {provider: razorpay,          PayPal button → POST /orders
                items:[…]}                                  {provider: paypal, items:[…]}
  → Razorpay Checkout opens (prefilled)      → PayPal approval popup
  → buyer pays (UPI/card)                    → onApprove → POST /orders/:id/paypal_capture

[Provider → Backend, server-to-server webhook = SOURCE OF TRUTH]
  Razorpay payment.captured  /  PayPal PAYMENT.CAPTURE.COMPLETED
  → verify signature → mark order paid → mint a 30-day/5-use token PER WORKSHEET
  → one Resend email listing every worksheet with its own download button

[Customer]  email → GET /download/:token → signed R2 URL → PDF (one link per worksheet).
[Admin]     order shows as paid, currency-aware amount, worksheet list, "Email: Sent".
```

**Trust boundary:** fulfilment depends only on the signature-verified webhook, never on
the browser. A user cannot fake a purchase or obtain a free download.

---

## 8. Admin panel

Server-rendered ERB, **Tailwind via CDN**, "French school exercise-book" theme (oxblood
`#3A1418` / cream `#FAF6EC` / red-ink `#A8362B`, Fraunces + IBM Plex Sans). Fully
usable on a phone: a collapsible top-bar nav, and a `.responsive-table` CSS pattern that
reflows wide tables into stacked, labelled cards below 768 px.

### Auth (single user, session-based)
- `Admin::BaseController < ActionController::Base` — `layout "admin"`,
  `before_action :require_login`; state is `session[:admin_authenticated]`.
- `Admin::SessionsController` — login at `/admin/login` (and at `/`, the root route).
  Username is the constant `"nidhi"`; the password comes from
  `credentials.admin.password`, compared with `ActiveSupport::SecurityUtils.secure_compare`
  (constant-time). `reset_session` on login. Blank credential ⇒ always fails.
- **Demo fallback (local only).** If the credentials carry no admin password —
  someone cloned the repo without the master key — `Admin::SessionsController`
  falls back to `DEMO_PASSWORD` in development and test **only**, so the app and its
  test suite are runnable by a reviewer. Outside those environments a missing
  credential still fails closed, and a real credential always wins. Pinned by tests.
- **Not** `has_secure_password`/bcrypt — a deliberate choice for a single-admin tool.
  The password lives in `credentials.yml.enc` (encrypted; master key is a Railway env
  var), never plaintext in the repo.
- `rescue_from StandardError` turns any unhandled admin error into a friendly flash
  ("nothing was saved — please try again") instead of a raw 500 page, and
  `RecordNotFound` into "that record no longer exists". **Re-raised in local envs** so
  real bugs still surface in development.

### Pages
- **Dashboard** (`/admin`) — revenue **split by currency** (₹ from Razorpay, $ from
  PayPal, summed from each order's snapshot), paid orders today / this week, product
  counts, **R2 storage used** (total blob bytes + file count), and the 8 most recent
  paid orders.
- **Products** — lists only `Product.listed`, with attachments eager-loaded so per-row
  file sizes don't trigger a query per row. Full CRUD including the R2 PDF upload and
  the preview image, prices in plain ₹ and $, and the **Remove** action (below).
- **Orders** — paginated (10/page), filterable by status (defaults to `paid`), by
  email/name (`ILIKE`, parameterized), and by worksheet — the worksheet filter matches
  **both** legacy `orders.product_id` and `order_items` rows. Detail page shows the full
  customer record, every line item with its own amount and download state, **"Resend
  download email"** (paid orders only), and **"Verify payment & fulfill"**.
- **Research** (`/admin/market_intelligence`) — read-only market intelligence from
  SerpApi (below).
- **Verify payment & fulfill** is the reconciliation path for a webhook that never
  arrived. It does **not** trust the click: it calls `Razorpay::Order.fetch` and only
  marks the order paid + emails if Razorpay itself reports `status == "paid"`.
  Otherwise it reports what Razorpay actually said and changes nothing.

### Research (Market Intelligence) — SerpApi
`/admin/market_intelligence`, added September 2026. Answers two questions the owner
actually has: *what should I make next?* and *how are we doing against everyone else?*

**Deliberately isolated.** Its only database writes are `serp_snapshots` cache rows, it
mints no token, and it changes no order. The demand-gap card does read the commerce tables,
but only as a `COUNT` of paid line items per product — **no amount, currency, token or
status is ever read**, so no bug here can misreport revenue or unlock a download. Nothing
in the payment/webhook/download path can be affected by it, and the page degrades to a
"SerpApi isn't set up yet" notice when no key is configured rather than erroring.

**Four cards, headed by the demand gap:**
0. **What to make next (`DemandGapAnalyzer`)** — the only card that joins SerpApi data to
   this store's own data, and the reason the feature is more than a rank tracker.
   - *Demand sources:* Google now answers many queries with an **AI Overview** and returns
     **no** `related_questions` / `related_searches` at all (verified against this store's
     own keywords). So demand is mined primarily from two other engines, with the classic
     SERP blocks still used when present:
     **`google_autocomplete`** (the long tail, ordered by popularity — weight decays with
     rank, floor 30) and **`google_trends`** `related_queries` (the only source carrying
     relative volume, 0-100; `"Breakout"` counts as 100). Scores sum per topic.
   - *Relevance:* Trends drifts badly — seeded with "french grammar" it returns "french
     toast near me" and "how to learn calligraphy" — so a phrase must contain a niche
     anchor (`french`) and must not contain an off-topic/wrong-product word (`app`,
     `course`, `tutor`, `near`, `translate`, `youtube`, `toast`, …). On real data this cut
     58 mined topics to 38, removing exactly the junk.
   - *Demand side:* every mined phrase is normalised, stripped of niche stopwords
     (`french`, `worksheet`, `pdf`, …) and
     **clustered by topic rather than by string** — first by identical meaningful-word set,
     then a second pass folding a more specific phrasing into the general topic whose words
     it contains (a general topic needs ≥2 words to absorb others, so one generic word
     can't swallow the list). Clustering is what makes a mention count mean demand rather
     than vocabulary.
   - *Supply side:* `Product.listed`, plus paid units per product counted across **both**
     rails — `order_items` joined to paid orders, merged with legacy `orders.product_id`.
     A `COUNT` only: **no amount, currency, token or status is read**, so this can never
     misreport revenue.
   - *Output:* uncovered topics ranked by mentions (the "make this next" list, each with a
     one-click Draft link), and every live worksheet labelled **Proven** (searched + sold),
     **Wanted, not selling** (searched, never sold — the listing is the problem, not the
     product), **Selling** (sold, no search signal) or **No signal yet**.
   - Coverage uses meaningful-word overlap against title + level + description at
     `COVERAGE_THRESHOLD = 0.6`, so "Verb Conjugation Drills" covers "french verb
     conjugation worksheet pdf". Phrases wanting it **free** are flagged.
   - Renders from cache only — **costs nothing to view**.
1. **Worksheet idea finder** — the owner types a rough topic ("french verb
   conjugation"); one **live, uncached** SerpApi call returns Google's
   `related_questions` ("People also ask") and `related_searches`. Each question links
   straight to `admin_new_product_path(title: …)`, so a real search query becomes a
   drafted worksheet in one click.
2. **Where we rank on Google** — position of `frenchworksheethub.com` in
   `organic_results` for the keywords in `TRACKED_KEYWORDS`, plus the top 5 results for
   each (ours highlighted). Read **only from the cache**.
3. **What similar worksheets sell for** — `google_shopping` results for `PRICING_QUERY`
   with a **median** listed price (median, not mean, so one mispriced bundle cannot move
   it). Labelled "as listed": Google returns each seller's own currency, so it is a
   signal, not a converted comparison.

**Quota discipline (the reason the cache table exists).** The free SerpApi tier is a
small monthly search budget, so **loading the page never spends a search**. Every cached
card renders from `serp_snapshots`, and refreshing is split into **two scoped POST-only
buttons** so one half never re-spends the other's budget:

| Button | `scope` | Spends | What it fetches |
|--------|---------|--------|-----------------|
| Refresh demand | `demand` | 6 | `google_autocomplete` + `google_trends`, once per `DEMAND_SEEDS` entry |
| Refresh ranks & prices | `ranks` | 6 | `google` per `TRACKED_KEYWORDS` entry + one `google_shopping` |

Each label states its own cost. POST-only matters: a page reload, a bookmark, or a crawler
can never burn quota. The idea finder is live by design and says so under the form.

Because the analyzer runs over the cache rather than the API, its scoring and filtering
were tuned by re-running against already-paid-for snapshots — **zero extra searches**.

**Configuration.** `TRACKED_KEYWORDS`, `PRICING_QUERY`, `OUR_DOMAIN` and
`SEARCH_LOCATION` are constants at the top of
`app/controllers/admin/market_intelligence_controller.rb` — edit them as the catalogue
grows. The key is `credentials.serpapi.api_key` (§10); without it the feature is inert,
which is also how it behaves in tests.

**Failure handling.** `SerpApiClient::Error` is caught per-search: a failed keyword
during Refresh is named in the flash and the others still cache; a failed topic lookup
renders an inline message. SerpApi reports quota exhaustion in an `error` key with an
HTTP **200**, so the client checks the body as well as the status code. The request URI
is never echoed into an error message — it carries the API key.

### Removing a worksheet
"Remove" reclaims paid R2 storage without damaging the books:
1. `purge_files!` deletes the PDF + preview from R2.
2. If the worksheet has **ever sold** (via `orders` *or* `order_items`), the record is
   kept and soft-removed (`removed_at`, `active: false`) so its revenue and order
   history survive.
3. If it never sold, the row is destroyed outright.
The flash reports how much storage was freed. Customers who open a link to a purged
file get a friendly message, not an error.

### Upload optimisation pipeline
On create/update, a freshly-uploaded PDF is shelled out to **Ghostscript**
(`-dPDFSETTINGS=/ebook`, 120 s timeout) and a preview image to **ImageMagick**
(flatten, `1600x1600>`, strip, quality 82 JPEG, 60 s timeout). Both follow the same
safety contract: **the original file is used unless the optimised one exists, is
non-empty, and is genuinely smaller** — and any exception, missing binary, or Windows
dev box short-circuits back to the original. The savings ("PDF 18.4 MB → 3.1 MB") are
appended to the success flash so the admin can see it happened.

### Route-naming convention (non-standard — follow it)
Admin routes are declared explicitly inside `namespace :admin` with custom `as:` names →
**`admin_<name>_path`** (e.g. `admin_new_product_path`, `admin_fulfill_order_path`), NOT
the Rails-standard `new_admin_product_path`. Do not use `resources` for admin routes.

---

## 9. Storefront (`french-tuiton-website/`, GitHub Pages)

Static site; design system in `style.css` (paper/ink/correction-red, Fraunces + Work
Sans + Caveat, ruled-margin schoolbook aesthetic).

**Pages:** `index`, `shop`, `about`, `contact`, plus legal pages `terms`, `privacy`,
`refund`, `shipping` (required by the payment providers; linked in every footer).

**`script.js`** (~1,000 lines, no build step, no framework):
- **HTTPS self-upgrade** at the top of the file: the backend's CORS only trusts the
  `https://` origin, so a page opened over `http://` immediately redirects. This exists
  because GitHub Pages silently resets "Enforce HTTPS" on some deploys.
- `API_BASE` → the Railway backend. `PAYPAL_CLIENT_ID` → the *public* PayPal client id.
- **Cart** — `localStorage` (`fwh_cart_v1`), a set of distinct slugs with no quantities,
  a header badge, and a cart modal. Prices in the cart are **display only**; the backend
  re-snapshots the authoritative price at order creation, so a tampered cart can't
  change what's charged.
- **Product grid** — `fetchProductsWithRetry()` retries `/products` three times with
  backoff, because most "couldn't load" cases are a backend cold start or a brief blip.
  All rendered values are HTML-escaped. A details modal formats the plain-text
  description into headings/bullets and shows the preview image.
- **Checkout modal** — collects customer fields; phone via **intl-tel-input** with
  country-aware `isValidNumber` validation. `collectCheckoutPayload()` validates before
  any network call — including *before* PayPal opens its window, so an invalid form
  shows an inline error instead of a broken popup.
- **Rail selection** — `detectBuyerCountry()` (geojs IP lookup) picks ₹/Razorpay or
  $/PayPal automatically; India defaults on failure. Only one method is shown at a time,
  and `submitCheckout` refuses to fire if the Razorpay button is hidden, so an Enter
  keypress can't start a ₹ order for an international buyer.
- **In-app browser handling** — Instagram/Facebook/TikTok webviews break payment popups,
  so those user agents are detected and shown a "copy link, open in Safari/Chrome" notice.
- **Analytics** — GA4 ecommerce events (`begin_checkout`, purchase, etc.) with a
  currency-correct `items`/`value` payload built from the cart.

`products.js` is a **legacy static product list, no longer loaded by any page** — the
catalogue now comes from the API.

---

## 10. Configuration

### `config/application.rb`
- `config.api_only = true`.
- **Sessions manually re-enabled** (cookie store + `Cookies` + session + `Flash` +
  `Rack::MethodOverride`) so the cookie-session admin panel works inside an api_only app.
- **`config.time_zone = "Asia/Kolkata"`** — admin displays IST; the DB stores UTC.

### `config/environments/production.rb`
- `eager_load = true`, `consider_all_requests_local = false`.
- **`force_ssl = true`** — HTTPS + HSTS + secure cookies.
- `active_storage.service = :r2`, with the AWS SDK's checksum behaviour set to
  `when_required` (R2 rejects the newer default checksum headers).
- Logs to STDOUT, tagged with `request_id`.

### `config/initializers/cors.rb`
Allows only `https://frenchworksheethub.com`, its `www`, and `http://localhost:<port>`.
`/products*` → GET; `/orders*` → POST. Webhooks are server-to-server (no CORS needed).

### `config/initializers/rack_attack.rb`
- Disabled in the test env (keeps tests deterministic); in-memory store.
- **Safelist:** `/webhooks/razorpay` + `/webhooks/paypal` — never throttled (they retry
  and are signature-verified).
- **Blocklist:** `POST /orders*` with a body > 16 KB, rejected before Rails parses it.
- **Throttles:** `POST /orders` 15 per 10 min per IP; `POST /admin/login` layered
  5/20 s (burst) + 20/10 min (sustained). Throttled clients get a JSON `429` with
  `Retry-After`.

### `config/initializers/filter_parameter_logging.rb`
Filters secrets **and customer PII** (`email, phone, name, address_line, city, state,
postal_code, country`) out of request logs.

### Cookies / CSRF
The session cookie is `HttpOnly` (default), `Secure` (via `force_ssl`), `SameSite=Lax`.
Admin controllers have CSRF protection; the JSON API doesn't need it; webhooks skip it
and rely on signature verification instead.

### `config/credentials.yml.enc` (decrypted with `RAILS_MASTER_KEY`)
```
secret_key_base
r2:       { access_key_id, secret_access_key, endpoint, bucket }
razorpay: { key_id, key_secret, webhook_secret }             # LIVE
paypal:   { mode, client_id, client_secret, webhook_id }     # LIVE (mode: "live")
resend:   { api_key }
serpapi:  { api_key }                                        # admin Research page only (§8)
admin:    { password }
```
Edit with `EDITOR="code --wait" bin/rails credentials:edit`.

---

## 11. Security practices (summary)

- **Payment trust:** fulfilment only via signature-verified webhooks (Razorpay HMAC;
  PayPal's verify-webhook-signature API); the amount is set server-side from the
  snapshot, so a buyer can't underpay; idempotent via status + email-sent guards.
- **Input:** allowlist strong params; model format + length validation on customer input
  (`on: :create`); parameterized queries (no SQLi); output escaping in admin views and
  in the HTML email.
- **Abuse / DoS:** rack-attack throttles + oversized-body blocklist; the PDF page-count
  memory guard.
- **Secrets:** all in encrypted credentials; only *public* payment key/client ids reach
  the browser; PII filtered from logs.
- **Transport & sessions:** force_ssl (HSTS), Secure/HttpOnly/SameSite cookies,
  constant-time admin compare, session reset on login.
- **Downloads:** unguessable per-item token, paid-gated, 30-day expiry, 5-download cap,
  signed short-lived R2 URL; refunds revoke access instantly.
- **Uploads:** content-type + size validation on both attachments; optimisation
  subprocesses are timeout-bounded and fail closed to the original file.
- **Supply chain:** `bundler-audit` for dependency CVE scanning.
- Reviewed against the OWASP Top 10 (no critical findings).

---

## 12. Payments (dual rail)

### Razorpay (India, INR)
- Live (`rzp_live_*`). Webhook → `/webhooks/razorpay`, events `payment.captured`,
  `refund.created`/`refund.processed`, `payment.failed`. HMAC signature verified;
  **failure raises Ruby `SecurityError`** (the gem has no dedicated error class).
- Amounts are integer paise end to end.

### PayPal (international, USD)
- Live. A hand-rolled `Net::HTTP` client (`app/services/paypal_client.rb`) because the
  official Ruby SDK is deprecated and the surface needed is tiny: get a token, create an
  order, capture it, verify a webhook. OAuth2 client-credentials token cached ~8 h in
  `Rails.cache` (PayPal's lifetime is ~9 h). 10 s open / 20 s read timeouts; non-2xx
  responses raise `PaypalClient::Error`, which controllers turn into a `502` and a
  friendly message.
- Flow: create order → buyer approves → server capture (`/orders/:id/paypal_capture`)
  **and/or** the `PAYMENT.CAPTURE.COMPLETED` webhook → fulfil (idempotent either way).
- The store operator is an **unregistered individual**, so PayPal is the route for
  foreign cards (Razorpay international cards require a registered business).
- **Fees:** international payments lose ~3–5% (fee + FX spread) and the fixed per-txn fee
  makes tiny amounts inefficient — price USD accordingly. New PayPal accounts also have
  a **funds hold (≤21 days)**: normal, not a bug.

---

## 13. Email (Resend)

Sent from `worksheets@frenchworksheethub.com` with `reply_to: frenchworksheethub@gmail.com`.
Branded HTML (table-based, inline styles, web-safe fonts) plus a plain-text alternative,
both built in `Order#download_email_html` / `#download_email_text`. Personalised with the
buyer's first name; **one card + download button per purchased worksheet**; a prominent
"please save your PDF now" panel stating the 5-open / 30-day limits; a support line. All
interpolated user input is HTML-escaped. The subject adapts to one vs. many worksheets.

Email is sent **inline** in the webhook (no job queue). Durability comes from the
provider's webhook retries plus the admin's Resend / Verify buttons.

---

## 14. File storage (Cloudflare R2)

`worksheet_pdf` and `preview_image` are Active Storage attachments on `Product`, stored
via the S3 adapter pointed at R2 (`config/storage.yml` + `aws-sdk-s3`,
`force_path_style: true`, `region: auto`). Downloads redirect to Active Storage's
**signed, expiring** R2 URL — the raw file URL is never public. The preview image is the
one exception, streamed publicly through the app with a 1-hour cache header. Dev and
test use the local Disk service, so no cloud credentials are needed to run locally.

The admin dashboard reports total stored bytes and file count, and the Remove flow purges
blobs to reclaim storage.

---

## 15. Deployment

### Backend (Railway)
- Multi-stage `Dockerfile` (build stage compiles gems; runtime stage adds `ghostscript`,
  `imagemagick`, `libvips`, `postgresql-client` and runs as a **non-root `rails` user**).
- `bin/docker-entrypoint` runs `db:prepare` before `rails server` → **migrations apply
  automatically on deploy**. This is why every migration here is additive and safe
  against live data.
- Required env vars: `RAILS_MASTER_KEY` (decrypts credentials), `APP_HOST` (download-link
  host; `RAILWAY_PUBLIC_DOMAIN` is the fallback), the DB connection, optional
  `RAILS_LOG_LEVEL`.
- `Gemfile.lock` pins platforms `x64-mingw-ucrt` (local Windows) **and** `x86_64-linux`
  (Railway) — keep both or native gems fail on deploy.
- Deploy = commit (including `Gemfile.lock`) + push. Credentials changes need no Railway
  variable change, since the master key is unchanged.

### Storefront (GitHub Pages)
Separate repo; push the `french-tuiton-website/` contents; `CNAME` maps the domain.
Update `API_BASE` in `script.js` if the backend URL changes. **Gotcha:** GitHub Pages can
reset "Enforce HTTPS" on deploy or if the CNAME goes missing, and an `http://` page can't
call the API (CORS trusts only the `https://` origin) — the script's self-upgrade
redirect exists to cover that. Backend and storefront deploy **independently**; push the
backend first when they change together.

---

## 16. Testing

Minitest + fixtures, threaded parallelisation; rack-attack disabled in tests.
`test/test_helper.rb` provides a `sign_in_admin` helper and `minitest/mock` for stubbing
Resend/Razorpay/SerpApi. 59 tests, deliberately concentrated where a bug costs money or
leaks a paid file:

**The suite runs serially on purpose** (`parallelize(workers: 1)`). It stubs *class*
methods, which are shared mutable state; Rails only enables threaded parallelism past 50
tests, so crossing that threshold silently corrupted the stubs
(`undefined method '__minitest_stub__api_key'`) until this was pinned.

| Area | What's covered |
|------|----------------|
| Downloads | valid token redirects + counts; unknown token, unpaid parent, refunded order, exhausted limit → 404 |
| Orders | required-field rejection; unknown/inactive product; multi-item cart snapshots the summed total; duplicate de-duplication; legacy `product_slug` still works; PayPal cart without a USD price rejected |
| Webhooks | missing signature → 400; invalid signature → 400; valid capture → paid **and** emailed; refund → downloads revoked |
| Admin | auth guards on dashboard/products/orders; `fulfill` marks paid when Razorpay confirms, and does **not** when it doesn't |
| Models | `worksheets_summary` singular vs. plural; `deliver_download_email!` mints one token per worksheet and sends exactly one email |
| Research (SerpApi) | auth guard on the page **and** on Refresh (a signed-out POST spends no search); renders with no key and no cache; rank + pricing read from cached snapshots; the topic form does exactly one live call and caches nothing; a SerpApi failure shows a message instead of a 500; Refresh caches one row per tracked keyword plus pricing |
| `SerpApiClient` | success parse; missing key; non-2xx → `Error`; an `error` key inside a **200** body → `Error`; connection timeout wrapped, not leaked. `Net::HTTP` is stubbed — tests never reach serpapi.com or spend quota |
| `SerpSnapshot` | stale rows excluded from `fresh_for` but still returned by `latest_for`; snapshots scoped per engine; `latest_for` returns the newest row |
| `DemandGapAnalyzer` | uncovered demand ranked; a specific phrasing folds into its general topic; a covered phrase is not reported as a gap; off-topic drift and wrong-product demand dropped; free-intent flagged; all four verdicts; paid units counted across cart **and** legacy orders while a pending order is ignored; empty cache doesn't raise |
| Scoped refresh | `scope=demand` spends autocomplete + Trends once per seed and **no** SERP/Shopping searches (and the reverse), with Trends' `data_type` set |

Run: `bin/rails test`.

---

## 17. Conventions & gotchas (read before editing)

- **Money is SNAPSHOTTED** (`orders.amount_cents` + `currency`, `order_items.unit_amount_cents`)
  at checkout — never derive an order's amount or revenue from the product's current price.
- **Read `order_items`, not `order.product`.** `orders.product_id` is nullable legacy;
  it exists only for pre-July-2026 orders and admin fallbacks.
- **Download tokens live on `OrderItem`**, one per worksheet, gated on the parent order's
  `paid` status. `Order::DOWNLOAD_LIMIT` / `DOWNLOAD_VALID_FOR` are the shared constants.
- **Two payment rails**: `payment_provider` + `currency` drive display, revenue, and
  verification. PayPal is a `Net::HTTP` service object, not a gem.
- **Money units**: INR in paise, USD in cents; the admin/API speak rupees/dollars via the
  `Product` accessors.
- **`Product.listed` is not a `default_scope`** — removed products must still resolve for
  order history.
- **Admin routes** use custom `admin_<name>_path` helpers, not Rails' standard nesting.
- **API-only app, but sessions are manually enabled** for the admin.
- **Razorpay signature failure = Ruby `SecurityError`**; **PayPal** verifies via its own
  API, not a local HMAC.
- **Time zone is IST** (`Asia/Kolkata`); the DB stores UTC.
- **Optimisation shell-outs must always fail open** to the original file.
- **Storefront is a separate git repo** → GitHub Pages, and must be served over HTTPS.
- **SerpApi searches are a metered resource.** Rendering the Research page must never
  spend one; only the POST-only Refresh button and the on-demand topic form may, and the
  UI must say what a click costs. The Research feature is read-only by contract — if a
  change there ever needs to touch an order, a token, or an amount, it belongs elsewhere.

---

## 18. Known limitations / roadmap

- **Single admin, no 2FA** (rate-limited login mitigates brute force). Admin auth is
  encrypted-credentials + constant-time compare, not bcrypt, by choice.
- **No background job queue** — email is sent inline in the webhook; durability comes from
  provider webhook retries plus the admin Resend/Verify buttons. A queue is the next
  correctness upgrade.
- **rack-attack and the PayPal token cache use in-memory stores** — correct for one Railway
  instance; horizontal scaling would need a shared store (Redis).
- **No customer accounts** — a buyer who loses their email loses their links until the
  admin resends. Accounts + order history are the next feature.
- **Ruby 3.1 is EOL** — an upgrade to 3.2+ is pending (also clears a nokogiri advisory).
- **Fixtures are still the Rails-generated placeholders**; tests build the records they
  need explicitly.
- **Next iteration** (see `ECOMMERCE_UPGRADE_PLAN.md`): Next.js + Tailwind storefront,
  customer accounts (email/password + Google OAuth, Rails-owned JWT), order history and
  re-download.
