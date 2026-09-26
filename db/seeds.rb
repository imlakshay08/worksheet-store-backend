# Demo data so anyone can clone this repo and see the whole thing working —
# including the Market Intelligence page — WITHOUT a SerpApi key and without the
# encrypted credentials.
#
#   bin/rails db:setup      # create, migrate, seed
#   bin/rails server        # then sign in at /admin/login
#
# `db/seeds/serp_samples.json` holds REAL SerpApi responses captured from the
# live store (autocomplete + Trends), trimmed exactly as the app trims them, so
# the demand-gap analysis runs on genuine Google data offline.
#
# Idempotent, and it refuses to touch production: the live store's catalogue and
# orders are real, and demo rows must never mix with them.
require "json"

if Rails.env.production?
  puts "[seeds] Production detected — refusing to insert demo data. Nothing written."
else
  puts "[seeds] Seeding demo catalogue, sales and cached search data…"

  # ---- catalogue ----------------------------------------------------------
  # Deliberately includes a worksheet with real demand that has never sold, so
  # the "Wanted, not selling" verdict has something to report.
  catalogue = [
    { slug: "french-articles-worksheet", title: "French Articles Worksheet",
      level: "A1", price_in_paise: 9900, price_in_cents: 300, page_count: 6,
      description: "Practice le, la, les, un, une, des with 60 graded gap-fill questions." },
    { slug: "french-verb-conjugation-drills", title: "French Verb Conjugation Drills",
      level: "A1-A2", price_in_paise: 14900, price_in_cents: 400, page_count: 10,
      description: "Present-tense conjugation practice for avoir, etre and regular -er verbs." },
    { slug: "french-numbers-1-to-100", title: "French Numbers 1 to 100",
      level: "A1", price_in_paise: 7900, price_in_cents: 200, page_count: 4,
      description: "Writing and listening practice for French numbers, with answer key." },
    { slug: "french-grammar-for-beginners", title: "French Grammar for Beginners",
      level: "A1", price_in_paise: 19900, price_in_cents: 500, page_count: 18,
      description: "A beginner grammar pack: articles, gender, plurals and basic sentence order." }
  ]

  products = catalogue.map do |attrs|
    product = Product.find_or_initialize_by(slug: attrs[:slug])
    product.assign_attributes(attrs.merge(active: true))
    product.save!(validate: false) # no attachments in demo data
    product
  end

  # ---- paid sales ---------------------------------------------------------
  # Only the first two have ever sold, so the catalogue shows a spread of
  # verdicts rather than one flat column.
  sales = { products[0] => 12, products[1] => 3 }

  sales.each do |product, units|
    units.times do |n|
      email = "demo-buyer-#{product.slug}-#{n}@example.com"
      next if Order.exists?(email: email)

      order = Order.create!(
        email: email, name: "Demo Buyer #{n + 1}", status: "paid",
        payment_provider: "razorpay", currency: "INR",
        amount_cents: product.price_in_paise, download_email_sent_at: Time.current
      )
      OrderItem.create!(order: order, product: product, unit_amount_cents: product.price_in_paise)
    end
  end

  # ---- cached SerpApi responses ------------------------------------------
  samples_path = Rails.root.join("db/seeds/serp_samples.json")

  if samples_path.exist?
    JSON.parse(samples_path.read).each do |row|
      next if SerpSnapshot.exists?(query: row["query"], engine: row["engine"])

      SerpSnapshot.create!(
        query: row["query"], engine: row["engine"],
        payload: row["payload"], fetched_at: Time.current
      )
    end
  end

  puts "[seeds] #{Product.count} products, #{Order.paid.count} paid orders, " \
       "#{SerpSnapshot.count} cached searches."
  puts "[seeds] Sign in at /admin/login as 'nidhi'. Without the encrypted " \
       "credentials, the development password is '#{Admin::SessionsController::DEMO_PASSWORD}'."
end
