class AddDownloadControlsToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :download_email_sent_at,    :datetime
    add_column :orders, :download_token_expires_at, :datetime
    add_column :orders, :download_count, :integer, null: false, default: 0
  end
end
