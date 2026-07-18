class CreateOrderItems < ActiveRecord::Migration[7.1]
  # Moves the store from one-product-per-order to a cart of distinct worksheets.
  #
  # Additive and safe to run against the live DB (it auto-runs on deploy):
  #   1. Create an empty order_items table.
  #   2. Relax orders.product_id to allow NULL (new multi-item orders have no
  #      single product). Only removes a constraint — never rewrites a row.
  #   3. Backfill: one line item per existing order, copying its product and its
  #      EXACT download token/expiry/count. Preserving the token string keeps
  #      every download link already emailed to customers working, because the
  #      download lookup moves from Order to OrderItem.
  def up
    create_table :order_items do |t|
      t.references :order,   null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true

      # Snapshot of this worksheet's price in the ORDER's currency (paise for
      # INR, cents for USD), frozen at checkout like the order's amount.
      t.integer :unit_amount_cents, null: false

      # Per-item download controls (a token unlocks one worksheet's PDF).
      t.string   :download_token
      t.datetime :download_token_expires_at
      t.integer  :download_count, null: false, default: 0

      t.timestamps
    end

    add_index :order_items, :download_token, unique: true

    change_column_null :orders, :product_id, true

    backfill_existing_orders
  end

  def down
    drop_table :order_items
    # We intentionally do NOT re-add the NOT NULL on orders.product_id: by the
    # time this is rolled back there may be multi-item orders with a null
    # product_id, and re-adding the constraint would fail. Left nullable.
  end

  private

  def backfill_existing_orders
    # Raw SQL against the current columns so the backfill is independent of the
    # app's model code (which will have moved on to the new schema).
    say_with_time "Backfilling order_items from existing orders" do
      execute(<<~SQL)
        INSERT INTO order_items
          (order_id, product_id, unit_amount_cents,
           download_token, download_token_expires_at, download_count,
           created_at, updated_at)
        SELECT
          o.id, o.product_id, COALESCE(o.amount_cents, 0),
          o.download_token, o.download_token_expires_at, COALESCE(o.download_count, 0),
          o.created_at, o.updated_at
        FROM orders o
        WHERE o.product_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.id)
      SQL
    end
  end
end
