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
end
