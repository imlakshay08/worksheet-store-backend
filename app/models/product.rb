class Product < ApplicationRecord
  has_one_attached :worksheet_pdf
  has_many :orders, dependent: :restrict_with_error
end
