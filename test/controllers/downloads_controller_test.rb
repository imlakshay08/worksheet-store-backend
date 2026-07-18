require "test_helper"

class DownloadsControllerTest < ActionDispatch::IntegrationTest
  def paid_item
    product = Product.create!(title: "DL", price_in_paise: 9900,
                              slug: "dl-#{SecureRandom.hex(4)}", active: true)
    product.worksheet_pdf.attach(io: StringIO.new("%PDF-1.4 test"),
                                 filename: "w.pdf", content_type: "application/pdf")
    order = Order.create!(email: "a@b.com", status: "paid", payment_provider: "razorpay",
                          currency: "INR", amount_cents: 9900)
    item = order.order_items.create!(product: product, unit_amount_cents: 9900)
    item.ensure_download_token!
    item
  end

  test "redirects a valid token to the worksheet and counts the download" do
    item = paid_item
    get "/download/#{item.download_token}"
    assert_response :redirect
    assert_equal 1, item.reload.download_count
  end

  test "404 for an unknown token" do
    get "/download/does-not-exist"
    assert_response :not_found
  end

  test "404 when the parent order isn't paid" do
    item = paid_item
    item.order.update!(status: "pending")
    get "/download/#{item.download_token}"
    assert_response :not_found
  end

  test "404 after the order is refunded" do
    item = paid_item
    item.order.mark_refunded!
    get "/download/#{item.download_token}"
    assert_response :not_found
  end

  test "404 once the per-item download limit is reached" do
    item = paid_item
    item.update!(download_count: Order::DOWNLOAD_LIMIT)
    get "/download/#{item.download_token}"
    assert_response :not_found
  end
end
