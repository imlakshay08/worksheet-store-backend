class Product < ApplicationRecord
  has_one_attached :worksheet_pdf
  has_many :orders, dependent: :restrict_with_error

  # The DB stores the price in paise (Razorpay needs paise), but the admin
  # types a plain rupee amount. These convert between the two.
  def price_in_rupees
    return if price_in_paise.nil?

    rupees = price_in_paise / 100.0
    rupees == rupees.to_i ? rupees.to_i : rupees
  end

  def price_in_rupees=(value)
    self.price_in_paise = value.present? ? (value.to_f * 100).round : nil
  end
end
