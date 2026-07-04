class AddPageCountToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :page_count, :integer
  end
end
