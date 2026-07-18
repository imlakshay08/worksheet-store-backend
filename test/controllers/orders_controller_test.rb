require "test_helper"

class OrdersControllerTest < ActionDispatch::IntegrationTest
  test "rejects an order missing required customer fields" do
    product = Product.create!(title: "Test", price_in_paise: 7900,
                              slug: "test-#{SecureRandom.hex(4)}", active: true)

    post orders_path, params: { product_slug: product.slug, email: "buyer@example.com" }, as: :json

    assert_response :unprocessable_entity
    assert_match(/name/, JSON.parse(response.body)["error"])
  end

  test "returns not found for an unknown or inactive product" do
    post orders_path,
         params: { product_slug: "does-not-exist", name: "A", email: "a@b.com", phone: "+91 99999" },
         as: :json

    assert_response :not_found
  end

  test "creates a multi-item razorpay order and snapshots the summed total" do
    p1 = Product.create!(title: "A", price_in_paise: 9900,  slug: "a-#{SecureRandom.hex(4)}", active: true)
    p2 = Product.create!(title: "B", price_in_paise: 14900, slug: "b-#{SecureRandom.hex(4)}", active: true)

    fake = Struct.new(:id).new("order_RZP1")
    Razorpay::Order.stub(:create, fake) do
      post orders_path, params: {
        items: [{ slug: p1.slug }, { slug: p2.slug }],
        name: "Buyer", email: "buyer@example.com", phone: "+91 9999999999"
      }, as: :json
    end

    assert_response :created
    order = Order.order(:created_at).last
    assert_equal 2, order.order_items.count
    assert_equal 9900 + 14900, order.amount_cents
    assert_equal "INR", order.currency
    assert_equal "order_RZP1", order.razorpay_order_id
  end

  test "de-duplicates the same worksheet added twice" do
    product = Product.create!(title: "A", price_in_paise: 9900, slug: "a-#{SecureRandom.hex(4)}", active: true)

    Razorpay::Order.stub(:create, Struct.new(:id).new("order_RZP2")) do
      post orders_path, params: {
        items: [{ slug: product.slug }, { slug: product.slug }],
        name: "Buyer", email: "buyer@example.com", phone: "+91 9999999999"
      }, as: :json
    end

    assert_response :created
    assert_equal 1, Order.order(:created_at).last.order_items.count
  end

  test "still accepts the legacy single product_slug and creates one line item" do
    product = Product.create!(title: "A", price_in_paise: 9900, slug: "a-#{SecureRandom.hex(4)}", active: true)

    Razorpay::Order.stub(:create, Struct.new(:id).new("order_RZP3")) do
      post orders_path, params: {
        product_slug: product.slug, name: "Buyer", email: "b@b.com", phone: "+91 99999999"
      }, as: :json
    end

    assert_response :created
    assert_equal 1, Order.order(:created_at).last.order_items.count
  end

  test "rejects a paypal cart when a worksheet has no international price" do
    p1 = Product.create!(title: "A", price_in_paise: 9900, price_in_cents: 200,
                         slug: "a-#{SecureRandom.hex(4)}", active: true)
    p2 = Product.create!(title: "B", price_in_paise: 9900, price_in_cents: nil,
                         slug: "b-#{SecureRandom.hex(4)}", active: true)

    post orders_path, params: {
      provider: "paypal", items: [{ slug: p1.slug }, { slug: p2.slug }],
      name: "Buyer", email: "buyer@example.com", phone: "+91 9999999999"
    }, as: :json

    assert_response :unprocessable_entity
  end
end
