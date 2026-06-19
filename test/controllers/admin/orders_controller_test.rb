require "test_helper"
require "ostruct"

class Admin::OrdersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @product = Product.create!(title: "Test", price_in_paise: 7900,
                               slug: "test-#{SecureRandom.hex(4)}", active: true)
  end

  test "requires login" do
    order = Order.create!(email: "b@e.com", product: @product, status: "pending")
    post admin_fulfill_order_path(order)
    assert_redirected_to admin_login_path
  end

  test "fulfill verifies with Razorpay and delivers when actually paid" do
    sign_in_admin
    order = Order.create!(email: "b@e.com", product: @product, status: "pending",
                          razorpay_order_id: "order_REC1")

    fake_order = OpenStruct.new(
      status: "paid",
      payments: OpenStruct.new(items: [OpenStruct.new(id: "pay_REC", status: "captured")])
    )

    Razorpay::Order.stub(:fetch, fake_order) do
      Resend::Emails.stub(:send, { id: "email_1" }) do
        post admin_fulfill_order_path(order)
      end
    end

    order.reload
    assert_equal "paid", order.status
    assert_equal "pay_REC", order.razorpay_payment_id
    assert order.download_email_sent_at.present?
  end

  test "fulfill does NOT mark paid when Razorpay says the order is not paid" do
    sign_in_admin
    order = Order.create!(email: "b@e.com", product: @product, status: "pending",
                          razorpay_order_id: "order_REC2")

    fake_order = OpenStruct.new(status: "attempted", payments: OpenStruct.new(items: []))

    Razorpay::Order.stub(:fetch, fake_order) do
      post admin_fulfill_order_path(order)
    end

    assert_equal "pending", order.reload.status
  end
end
