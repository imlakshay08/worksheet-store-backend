class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def razorpay
    payload_body = request.raw_post
    signature = request.headers["X-Razorpay-Signature"]
    webhook_secret = Rails.application.credentials.dig(:razorpay, :webhook_secret)

    begin
      Razorpay::Utility.verify_webhook_signature(
        payload_body,
        signature,
        webhook_secret
      )
    rescue SecurityError
      render json: { error: "Invalid signature" }, status: :bad_request
      return
    end

    event = JSON.parse(payload_body)

    if event["event"] == "payment.captured"
      payment_entity = event.dig("payload", "payment", "entity") || {}
      order = Order.find_by(razorpay_order_id: payment_entity["order_id"])

      if order
        # Defense-in-depth: Razorpay binds the amount to the order, but flag any
        # mismatch loudly in case of a future bug or tampering attempt.
        if payment_entity["amount"].to_i != order.amount_in_paise
          Rails.logger.warn(
            "Razorpay amount mismatch for order #{order.id}: " \
            "captured #{payment_entity['amount']} expected #{order.amount_in_paise}"
          )
        end

        # 1. Record the payment first so it's never lost, even if email fails.
        if order.status != "paid"
          order.update!(status: "paid", razorpay_payment_id: payment_entity["id"])
        end

        # 2. Deliver the download email exactly once. If this raises, the whole
        #    action returns 500 and Razorpay retries the webhook later; the
        #    payment is already recorded, so only the email step re-runs.
        order.deliver_download_email! unless order.download_email_sent_at
      end
    end

    render json: { received: true }, status: :ok
  end
end
