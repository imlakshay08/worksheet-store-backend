require "test_helper"

class OrderTest < ActiveSupport::TestCase
  def make_product(price = 9900)
    Product.create!(title: "P-#{SecureRandom.hex(3)}", price_in_paise: price,
                    slug: "p-#{SecureRandom.hex(4)}", active: true)
  end

  def paid_order(amount)
    Order.create!(email: "a@b.com", status: "paid", payment_provider: "razorpay",
                  currency: "INR", amount_cents: amount)
  end

  test "worksheets_summary shows the title for one item and a count for many" do
    order = paid_order(9900)
    p1 = make_product
    order.order_items.create!(product: p1, unit_amount_cents: 9900)
    assert_equal p1.title, order.reload.worksheets_summary

    order.order_items.create!(product: make_product, unit_amount_cents: 9900)
    assert_equal "2 worksheets", order.reload.worksheets_summary
  end

  test "deliver_download_email! issues a token per worksheet and sends exactly one email" do
    order = paid_order(19800)
    order.order_items.create!(product: make_product, unit_amount_cents: 9900)
    order.order_items.create!(product: make_product, unit_amount_cents: 9900)

    calls = 0
    Resend::Emails.stub(:send, ->(*_) { calls += 1; { id: "e" } }) do
      order.deliver_download_email!
    end

    assert_equal 1, calls, "one email covers the whole order"
    assert order.order_items.all? { |i| i.reload.download_token.present? }, "every item gets its own token"
    assert order.reload.download_email_sent_at.present?
  end
end
