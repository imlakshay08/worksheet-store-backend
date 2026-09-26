# Copy the LIVE store's Research-page data down to a local machine, so the
# feature can be demonstrated locally with real numbers.
#
#   # 1. against production (read-only — exports to a JSON file)
#   DATABASE_URL="<railway postgres url>" bin/rails demo:export
#
#   # 2. back on your own machine
#   bin/rails demo:import
#
# What it deliberately does NOT copy: customers. No name, email, phone or
# address ever leaves production. Sales are reproduced as anonymous placeholder
# orders whose COUNT per worksheet matches the real one, which is all the
# demand-gap analysis reads. Amounts are copied from the product's own price,
# never from an order, so no real payment figure travels either.
namespace :demo do
  DEMO_EXPORT_PATH = "tmp/demo_data.json".freeze

  desc "Export catalogue, per-product paid unit counts and cached SerpApi data (no customer data)"
  task export: :environment do
    require "json"

    products = Product.listed.map do |product|
      product.slice(
        "slug", "title", "description", "level",
        "price_in_paise", "price_in_cents", "page_count", "active"
      )
    end

    payload = {
      "exported_at" => Time.current.iso8601,
      "products"    => products,
      "units_sold"  => DemandGapAnalyzer.paid_units_by_product
                                        .transform_keys { |id| Product.find_by(id: id)&.slug }
                                        .compact,
      "snapshots"   => SerpSnapshot.newest_first.limit(40).map { |snapshot|
        snapshot.slice("query", "engine", "payload")
      }
    }

    FileUtils.mkdir_p(File.dirname(DEMO_EXPORT_PATH))
    File.write(DEMO_EXPORT_PATH, JSON.pretty_generate(payload))

    puts "[demo:export] #{payload['products'].size} products, " \
         "#{payload['units_sold'].values.sum} paid units, " \
         "#{payload['snapshots'].size} cached searches"
    puts "[demo:export] written to #{DEMO_EXPORT_PATH} — no customer data included."
  end

  desc "Load an exported file into the LOCAL database (replaces local catalogue, orders and snapshots)"
  task import: :environment do
    require "json"

    unless Rails.env.development? || Rails.env.test?
      abort "[demo:import] Refusing to run outside development/test. This replaces data."
    end

    # Rails.env alone is NOT enough here. demo:export is meant to be run with
    # DATABASE_URL pointing at production, and if that variable is still set on
    # the next command the environment is *development* while the connection is
    # *production* — and this task deletes rows. So check the connection itself.
    if ENV["DATABASE_URL"].present?
      abort "[demo:import] DATABASE_URL is set. Unset it first — this task must " \
            "only ever touch your local database."
    end

    host = ActiveRecord::Base.connection_db_config.configuration_hash[:host].to_s
    unless ["", "localhost", "127.0.0.1", "::1"].include?(host)
      abort "[demo:import] Connected to #{host.inspect}, which is not a local database. Refusing."
    end

    unless File.exist?(DEMO_EXPORT_PATH)
      abort "[demo:import] #{DEMO_EXPORT_PATH} not found. Run demo:export against production first."
    end

    data = JSON.parse(File.read(DEMO_EXPORT_PATH))

    puts "[demo:import] Replacing local products, orders and cached searches…"
    OrderItem.delete_all
    Order.delete_all
    Product.delete_all
    SerpSnapshot.delete_all

    products = data["products"].to_h do |attrs|
      product = Product.new(attrs)
      product.save!(validate: false) # no attachments travel with the export
      [attrs["slug"], product]
    end

    data["units_sold"].each do |slug, units|
      product = products[slug]
      next if product.nil?

      units.to_i.times do |n|
        order = Order.create!(
          email: "local-demo-#{slug}-#{n}@example.com", name: "Local Demo",
          status: "paid", payment_provider: "razorpay", currency: "INR",
          amount_cents: product.price_in_paise.to_i, download_email_sent_at: Time.current
        )
        OrderItem.create!(order: order, product: product,
                          unit_amount_cents: product.price_in_paise.to_i)
      end
    end

    data["snapshots"].each do |snapshot|
      SerpSnapshot.create!(
        query: snapshot["query"], engine: snapshot["engine"],
        payload: snapshot["payload"], fetched_at: Time.current
      )
    end

    puts "[demo:import] #{Product.count} products, #{Order.paid.count} paid orders, " \
         "#{SerpSnapshot.count} cached searches. Start the server and open /admin/market_intelligence."
  end
end
