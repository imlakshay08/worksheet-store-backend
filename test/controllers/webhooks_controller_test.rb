require "test_helper"

class WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @secret  = Rails.application.credentials.dig(:razorpay, :webhook_secret)
    @product = Product.create!(title: "Test", price_in_paise: 7900,
                               slug: "test-#{SecureRandom.hex(4)}", active: true)
    @order = Order.create!(email: "buyer@example.com", product: @product,
                           status: "pending", razorpay_order_id: "order_TEST123")
  end

  def captured_payload
    {
      event: "payment.captured",
      payload: { payment: { entity: { order_id: "order_TEST123", id: "pay_TEST", amount: 7900 } } }
    }.to_json
  end

  test "rejects a webhook with an invalid signature" do
    post "/webhooks/razorpay", params: captured_payload,
         headers: { "X-Razorpay-Signature" => "wrong", "Content-Type" => "application/json" }

    assert_response :bad_request
    assert_equal "pending", @order.reload.status
  end

  test "marks the order paid and delivers the download email on a valid event" do
    signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, captured_payload)

    Resend::Emails.stub(:send, { id: "email_1" }) do
      post "/webhooks/razorpay", params: captured_payload,
           headers: { "X-Razorpay-Signature" => signature, "Content-Type" => "application/json" }
    end

    assert_response :ok
    @order.reload
    assert_equal "paid", @order.status
    assert_equal "pay_TEST", @order.razorpay_payment_id
    assert @order.download_token.present?
    assert @order.download_email_sent_at.present?
  end
end
