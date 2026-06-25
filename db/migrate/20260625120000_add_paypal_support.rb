class AddPaypalSupport < ActiveRecord::Migration[7.1]
  def change
    # Which rail handled this order. Existing rows are all Razorpay.
    add_column :orders, :payment_provider, :string, default: "razorpay", null: false
    add_column :orders, :paypal_order_id, :string
    add_column :orders, :paypal_capture_id, :string
    add_index  :orders, :paypal_order_id

    # International price in USD cents (mirrors products.price_in_paise for INR).
    # Nullable: a worksheet with no USD price simply isn't sold internationally.
    add_column :products, :price_in_cents, :integer
  end
end
