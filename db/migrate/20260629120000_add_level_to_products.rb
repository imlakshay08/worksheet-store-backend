class AddLevelToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :level, :string
  end
end
