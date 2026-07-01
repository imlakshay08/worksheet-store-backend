class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def razorpay
    payload_body = request.raw_post
    signature = request.headers["X-Razorpay-Signature"]

    # Reject obviously-malformed requests (e.g. probes) with a clean 400.
    if signature.blank?
      render json: { error: "Missing signature" }, status: :bad_request
      return
    end

    begin
      Razorpay::Utility.verify_webhook_signature(
        payload_body,
        signature,
        Rails.application.credentials.dig(:razorpay, :webhook_secret)
      )
    rescue SecurityError
      render json: { error: "Invalid signature" }, status: :bad_request
      return
    end

    event = JSON.parse(payload_body)

    case event["event"]
    when "payment.captured"
      handle_payment_captured(event)
    when "refund.created", "refund.processed"
      handle_refund(event)
    when "payment.failed"
      handle_payment_failed(event)
    end

    render json: { received: true }, status: :ok
  end

  def paypal
    payload_body = request.raw_post

    begin
      event = JSON.parse(payload_body)
    rescue JSON::ParserError
      render json: { error: "Invalid payload" }, status: :bad_request
      return
    end

    unless PaypalClient.verify_webhook(headers: request.headers, body: event)
      render json: { error: "Invalid signature" }, status: :bad_request
      return
    end

    case event["event_type"]
    when "PAYMENT.CAPTURE.COMPLETED"
      handle_paypal_capture_completed(event)
    when "PAYMENT.CAPTURE.REFUNDED", "PAYMENT.CAPTURE.REVERSED"
      handle_paypal_refund(event)
    end

    render json: { received: true }, status: :ok
  end

  private

  def handle_payment_captured(event)
    entity = event.dig("payload", "payment", "entity") || {}
    order = Order.find_by(razorpay_order_id: entity["order_id"])
    return unless order

    # Defense-in-depth: Razorpay binds the amount to the order, but flag any
    # mismatch loudly in case of a future bug or tampering attempt.
    if entity["amount"].to_i != order.expected_amount_minor
      Rails.logger.warn(
        "Razorpay amount mismatch for order #{order.id}: " \
        "captured #{entity['amount']} expected #{order.expected_amount_minor}"
      )
    end

    # 1. Record the payment first so it's never lost, even if email fails.
    order.update!(status: "paid", razorpay_payment_id: entity["id"]) if order.status != "paid"

    # 2. Deliver the download email exactly once. If this raises, the whole
    #    action returns 500 and Razorpay retries the webhook later; the
    #    payment is already recorded, so only the email step re-runs.
    order.deliver_download_email! unless order.download_email_sent_at
  end

  def handle_refund(event)
    entity = event.dig("payload", "refund", "entity") || {}
    order = Order.find_by(razorpay_payment_id: entity["payment_id"])
    return unless order

    order.mark_refunded!
    Rails.logger.info("Order #{order.id} marked refunded (refund #{entity['id']}); download access revoked.")
  end

  def handle_payment_failed(event)
    entity = event.dig("payload", "payment", "entity") || {}
    order = Order.find_by(razorpay_order_id: entity["order_id"])
    return unless order

    # Nothing to fulfil; the order stays pending so the buyer can retry.
    Rails.logger.info("Razorpay payment failed for order #{order.id}.")
  end

  # --- PayPal -------------------------------------------------------------

  def handle_paypal_capture_completed(event)
    capture = event["resource"] || {}
    order   = find_paypal_order(capture)
    return unless order

    expected = order.expected_amount_decimal_string
    if expected.present? && capture.dig("amount", "value") != expected
      Rails.logger.warn(
        "PayPal amount mismatch for order #{order.id}: " \
        "captured #{capture.dig('amount', 'value')} expected #{expected}"
      )
    end

    # 1. Record the payment first so it's never lost, even if email fails.
    order.update!(status: "paid", paypal_capture_id: capture["id"]) if order.status != "paid"

    # 2. Deliver exactly once. If this raises, we return 500 and PayPal retries;
    #    the payment is already recorded, so only the email step re-runs.
    order.deliver_download_email! unless order.download_email_sent_at
  end

  def handle_paypal_refund(event)
    refund     = event["resource"] || {}
    capture_id = paypal_parent_capture_id(refund)
    order      = Order.find_by(paypal_capture_id: capture_id) if capture_id
    return unless order

    order.mark_refunded!
    Rails.logger.info("Order #{order.id} marked refunded (PayPal refund #{refund['id']}); download access revoked.")
  end

  # Match a PayPal capture resource to our order. We set custom_id to our order
  # id at creation; fall back to the related PayPal order id if it's missing.
  def find_paypal_order(capture)
    if capture["custom_id"].present?
      order = Order.find_by(id: capture["custom_id"])
      return order if order
    end

    paypal_order_id = capture.dig("supplementary_data", "related_ids", "order_id")
    Order.find_by(paypal_order_id: paypal_order_id) if paypal_order_id.present?
  end

  # A refund resource links back to its parent capture via a "up" HATEOAS link
  # like .../v2/payments/captures/<capture_id>.
  def paypal_parent_capture_id(refund)
    link = (refund["links"] || []).find { |l| l["rel"] == "up" }
    link && link["href"].to_s.split("/").last.presence
  end
end
