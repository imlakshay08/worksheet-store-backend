require "test_helper"

class WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @secret  = Rails.application.credentials.dig(:razorpay, :webhook_secret)
    @product = Product.create!(title: "Test", price_in_paise: 7900,
                               slug: "test-#{SecureRandom.hex(4)}", active: true)
    @order = Order.create!(email: "buyer@example.com", product: @product,
                           status: "pending", razorpay_order_id: "order_TEST123")
  end

  def signed_post(payload)
    signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)
    post "/webhooks/razorpay", params: payload,
         headers: { "X-Razorpay-Signature" => signature, "Content-Type" => "application/json" }
  end

  def captured_payload
    {
      event: "payment.captured",
      payload: { payment: { entity: { order_id: "order_TEST123", id: "pay_TEST", amount: 7900 } } }
    }.to_json
  end

  test "rejects a webhook with a missing signature header" do
    post "/webhooks/razorpay", params: captured_payload,
         headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    assert_equal "pending", @order.reload.status
  end

  test "rejects a webhook with an invalid signature" do
    post "/webhooks/razorpay", params: captured_payload,
         headers: { "X-Razorpay-Signature" => "wrong", "Content-Type" => "application/json" }

    assert_response :bad_request
    assert_equal "pending", @order.reload.status
  end

  test "marks the order paid and delivers the download email on a valid event" do
    Resend::Emails.stub(:send, { id: "email_1" }) do
      signed_post(captured_payload)
    end

    assert_response :ok
    @order.reload
    assert_equal "paid", @order.status
    assert_equal "pay_TEST", @order.razorpay_payment_id
    assert @order.download_token.present?
    assert @order.download_email_sent_at.present?
  end

  test "marks the order refunded and revokes the download on a refund event" do
    Resend::Emails.stub(:send, { id: "email_1" }) { signed_post(captured_payload) }
    assert @order.reload.download_available?, "should be downloadable after payment"

    refund_payload = {
      event: "refund.created",
      payload: { refund: { entity: { id: "rfnd_X", payment_id: "pay_TEST" } } }
    }.to_json
    signed_post(refund_payload)

    assert_response :ok
    @order.reload
    assert_equal "refunded", @order.status
    assert_not @order.download_available?, "download link must be revoked after refund"
  end
end
