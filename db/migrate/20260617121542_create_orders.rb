class CreateOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :orders do |t|
      t.string :email
      t.references :product, null: false, foreign_key: true
      t.string :status
      t.string :download_token
      t.string :razorpay_order_id
      t.string :razorpay_payment_id

      t.timestamps
    end
  end
end
