class AddCustomerDetailsToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :name,         :string
    add_column :orders, :phone,        :string
    add_column :orders, :address_line, :string
    add_column :orders, :city,         :string
    add_column :orders, :state,        :string
    add_column :orders, :postal_code,  :string
    add_column :orders, :country,      :string
  end
end
