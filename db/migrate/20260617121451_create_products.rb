class CreateProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :products do |t|
      t.string :title
      t.text :description
      t.integer :price_in_paise
      t.string :slug
      t.boolean :active

      t.timestamps
    end
  end
end
