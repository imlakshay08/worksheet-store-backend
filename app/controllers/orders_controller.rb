class OrdersController < ApplicationController
  CUSTOMER_FIELDS = %i[name email phone address_line city state postal_code country].freeze
  REQUIRED_FIELDS = %i[name email phone].freeze

  def create
    slugs = requested_slugs
    if slugs.empty?
      render json: { error: "Your cart is empty." }, status: :unprocessable_entity
      return
    end

    # Load the requested worksheets, preserving the cart order. Any slug that
    # isn't a currently-active product means the cart is stale.
    by_slug   = Product.where(slug: slugs, active: true).index_by(&:slug)
    products  = slugs.map { |s| by_slug[s] }.compact
    if products.size != slugs.size
      render json: { error: "One or more worksheets in your cart aren't available anymore. Please refresh and try again." },
             status: :not_found
      return
    end

    details = customer_params
    missing = REQUIRED_FIELDS.select { |field| details[field].blank? }
    if missing.any?
      render json: { error: "Please fill in: #{missing.map(&:to_s).join(', ')}." },
             status: :unprocessable_entity
      return
    end

    provider = params[:provider] == "paypal" ? "paypal" : "razorpay"
    currency = provider == "paypal" ? "USD" : "INR"

    # Snapshot each worksheet's price NOW, in the order's currency, so editing a
    # product's price later never rewrites this order. The order total is the sum.
    price_of = ->(p) { provider == "paypal" ? p.price_in_cents : p.price_in_paise }

    if provider == "paypal" && products.any? { |p| p.price_in_cents.blank? }
      render json: { error: "International checkout isn't available for one of these worksheets yet." },
             status: :unprocessable_entity
      return
    end

    order = Order.new(details.merge(
      status: "pending", payment_provider: provider,
      currency: currency, amount_cents: products.sum { |p| price_of.call(p).to_i }
    ))
    products.each { |p| order.order_items.build(product: p, unit_amount_cents: price_of.call(p)) }

    unless order.save
      render json: { error: order.errors.full_messages.to_sentence }, status: :unprocessable_entity
      return
    end

    if provider == "paypal"
      start_paypal_order(order, products)
    else
      start_razorpay_order(order, products)
    end
  end

  def show
    order = Order.includes(order_items: :product).find(params[:id])
    render json: {
      status: order.status,
      product_title: order_summary_title(order)
    }
  end

  # PayPal Smart Buttons call this from their onApprove callback. We capture the
  # money server-side, then fulfil. The PayPal webhook is the source of truth and
  # will (idempotently) re-fulfil if it arrives first or this request is lost.
  def paypal_capture
    order = Order.find(params[:id])

    if !order.paypal? || order.paypal_order_id.blank?
      render json: { error: "This order isn't a PayPal order." }, status: :unprocessable_entity
      return
    end

    if order.status == "paid"
      render json: { status: "paid" }
      return
    end

    result  = PaypalClient.capture_order(order.paypal_order_id)
    capture = result.dig("purchase_units", 0, "payments", "captures", 0) || {}

    if result["status"] == "COMPLETED" && capture["status"] == "COMPLETED"
      fulfill_paypal!(order, capture)
      render json: { status: "paid" }
    else
      Rails.logger.warn("PayPal capture not completed for order #{order.id}: #{result['status']}")
      render json: { error: "Your payment couldn't be completed. Please try again." },
             status: :unprocessable_entity
    end
  rescue PaypalClient::Error => e
    Rails.logger.error("PayPal capture failed for order #{params[:id]}: #{e.message}")
    render json: { error: "We couldn't confirm your payment. If you were charged, contact us and we'll sort it out." },
           status: :bad_gateway
  end

  private

  def start_razorpay_order(order, products)
    razorpay_order = Razorpay::Order.create(
      "amount"   => order.amount_cents,
      "currency" => "INR",
      "receipt"  => "order_#{order.id}",
      "notes"    => {
        "internal_order_id" => order.id,
        "customer_name"     => order.name,
        "customer_phone"    => order.phone,
        "customer_city"     => order.city,
        "customer_country"  => order.country
      }
    )

    order.update!(razorpay_order_id: razorpay_order.id)

    render json: {
      order_id:          order.id,
      razorpay_order_id: razorpay_order.id,
      razorpay_key_id:   Rails.application.credentials.dig(:razorpay, :key_id),
      amount:            order.amount_cents,
      product_title:     checkout_title(products)
    }, status: :created
  end

  def start_paypal_order(order, products)
    paypal_order = PaypalClient.create_order(
      reference:   "order_#{order.id}",
      custom_id:   order.id.to_s,
      amount:      order.expected_amount_decimal_string,
      currency:    "USD",
      description: checkout_title(products)
    )

    order.update!(paypal_order_id: paypal_order["id"])

    render json: {
      order_id:        order.id,
      paypal_order_id: paypal_order["id"]
    }, status: :created
  rescue PaypalClient::Error => e
    Rails.logger.error("PayPal order creation failed for order #{order.id}: #{e.message}")
    render json: { error: "We couldn't start the PayPal checkout. Please try again in a moment." },
           status: :bad_gateway
  end

  # The worksheet slugs the buyer is checking out. Accepts the new cart format
  # (items: [{slug: "..."}] or ["slug", ...]) and the legacy single product_slug,
  # so the current storefront keeps working until the cart UI ships. De-duped:
  # a worksheet is a digital file you either own or don't — no quantities.
  def requested_slugs
    raw =
      if params[:items].present?
        Array(params[:items]).map { |i| i.respond_to?(:[]) ? i[:slug] : i }
      elsif params[:product_slug].present?
        [params[:product_slug]]
      else
        []
      end

    raw.map { |s| s.to_s.strip }.reject(&:blank?).uniq
  end

  # Human label for a checkout spanning one or more worksheets. Kept short for
  # PayPal's description field (which has a length cap).
  def checkout_title(products)
    return products.first.title if products.size == 1

    "#{products.size} French worksheets"
  end

  # Title shown by the lightweight status endpoint.
  def order_summary_title(order)
    items = order.order_items.to_a
    return order.product&.title if items.empty?

    checkout_title(items.map(&:product))
  end

  # Shared fulfilment for a completed PayPal capture. Idempotent: safe to call
  # from both this controller and the webhook.
  def fulfill_paypal!(order, capture)
    expected = order.expected_amount_decimal_string
    if expected.present? && capture.dig("amount", "value") != expected
      Rails.logger.warn(
        "PayPal amount mismatch for order #{order.id}: " \
        "captured #{capture.dig('amount', 'value')} expected #{expected}"
      )
    end

    order.update!(status: "paid", paypal_capture_id: capture["id"]) if order.status != "paid"
    order.deliver_download_email! unless order.download_email_sent_at
  end

  def customer_params
    params.permit(*CUSTOMER_FIELDS).to_h.symbolize_keys
  end
end
