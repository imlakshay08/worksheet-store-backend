class OrdersController < ApplicationController
  CUSTOMER_FIELDS = %i[name email phone address_line city state postal_code country].freeze
  REQUIRED_FIELDS = %i[name email phone].freeze

  def create
    product = Product.find_by(slug: params[:product_slug], active: true)

    if product.nil?
      render json: { error: "This worksheet isn't available right now." }, status: :not_found
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
    order = Order.create!(details.merge(product: product, status: "pending", payment_provider: provider))

    if provider == "paypal"
      start_paypal_order(order, product)
    else
      start_razorpay_order(order, product)
    end
  end

  def show
    order = Order.find(params[:id])
    render json: {
      status: order.status,
      product_title: order.product.title
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

  def start_razorpay_order(order, product)
    razorpay_order = Razorpay::Order.create(
      "amount"   => product.price_in_paise,
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
      amount:            product.price_in_paise,
      product_title:     product.title
    }, status: :created
  end

  def start_paypal_order(order, product)
    if product.price_in_cents.blank?
      render json: { error: "International checkout isn't available for this worksheet yet." },
             status: :unprocessable_entity
      return
    end

    paypal_order = PaypalClient.create_order(
      reference:   "order_#{order.id}",
      custom_id:   order.id.to_s,
      amount:      product.usd_amount_string,
      currency:    "USD",
      description: product.title
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

  # Shared fulfilment for a completed PayPal capture. Idempotent: safe to call
  # from both this controller and the webhook.
  def fulfill_paypal!(order, capture)
    expected = order.product.usd_amount_string
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
