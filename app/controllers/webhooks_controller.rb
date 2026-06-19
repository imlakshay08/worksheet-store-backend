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

  private

  def handle_payment_captured(event)
    entity = event.dig("payload", "payment", "entity") || {}
    order = Order.find_by(razorpay_order_id: entity["order_id"])
    return unless order

    # Defense-in-depth: Razorpay binds the amount to the order, but flag any
    # mismatch loudly in case of a future bug or tampering attempt.
    if entity["amount"].to_i != order.amount_in_paise
      Rails.logger.warn(
        "Razorpay amount mismatch for order #{order.id}: " \
        "captured #{entity['amount']} expected #{order.amount_in_paise}"
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
end
