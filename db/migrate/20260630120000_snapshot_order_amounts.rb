class SnapshotOrderAmounts < ActiveRecord::Migration[7.1]
  def up
    add_column :orders, :amount_cents, :integer
    add_column :orders, :currency, :string

    # Backfill existing orders from their product's CURRENT price (best effort;
    # orders placed while a price was different may be approximate — the exact
    # figure lives in the Razorpay/PayPal dashboard). From now on, new orders
    # snapshot the real amount at checkout and never change.
    execute <<~SQL
      UPDATE orders o
      SET currency = CASE WHEN o.payment_provider = 'paypal' THEN 'USD' ELSE 'INR' END,
          amount_cents = CASE
            WHEN o.payment_provider = 'paypal'
              THEN (SELECT p.price_in_cents FROM products p WHERE p.id = o.product_id)
            ELSE (SELECT p.price_in_paise FROM products p WHERE p.id = o.product_id)
          END
      WHERE o.amount_cents IS NULL
    SQL
  end

  def down
    remove_column :orders, :amount_cents
    remove_column :orders, :currency
  end
end
