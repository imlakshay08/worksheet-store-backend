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
    rescue Razorpay::SignatureVerificationError
      render json: { error: "Invalid signature" }, status: :bad_request
      return
    end

    event = JSON.parse(payload_body)

    if event["event"] == "payment.captured"
      payment_entity = event["payload"]["payment"]["entity"]
      razorpay_order_id = payment_entity["order_id"]
      razorpay_payment_id = payment_entity["id"]

      order = Order.find_by(razorpay_order_id: razorpay_order_id)

      if order && order.status != "paid"
        order.update!(
          status: "paid",
          razorpay_payment_id: razorpay_payment_id,
          download_token: SecureRandom.urlsafe_base64(32)
        )

          Resend::Emails.send(
            {
              from: "French Worksheet Hub <worksheets@frenchworksheethub.com>",
              to: order.email,
              subject: "Your worksheet: #{order.product.title}",
              html: "<p>Thanks for your purchase! Download your worksheet here:</p><p><a href=\"#{order.download_url}\">#{order.download_url}</a></p>"
            }
          )
      end
    end

    render json: { received: true }, status: :ok
  end
end