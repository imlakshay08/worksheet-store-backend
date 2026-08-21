class AddRemovedAtToProducts < ActiveRecord::Migration[7.1]
  def change
    # Soft-delete flag: NULL = live/visible, timestamp = removed from the admin
    # (hidden from the list, files purged) while the record stays for order history.
    add_column :products, :removed_at, :datetime
    add_index  :products, :removed_at
  end
end
