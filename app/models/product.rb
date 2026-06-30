class Product < ApplicationRecord
  has_one_attached :worksheet_pdf
  has_many :orders, dependent: :restrict_with_error

  MAX_PDF_BYTES = 20.megabytes

  validates :title, presence: true, length: { maximum: 150 }
  validates :slug,  presence: true, length: { maximum: 100 },
                    format: { with: /\A[a-z0-9-]+\z/, message: "can only contain lowercase letters, numbers, and dashes" },
                    uniqueness: { case_sensitive: false }
  validates :description, length: { maximum: 8000 }, allow_blank: true
  validates :level,       length: { maximum: 40 },   allow_blank: true
  validate  :worksheet_pdf_must_be_a_reasonable_pdf

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

  # International (PayPal) price in USD. Stored as cents, typed in dollars in
  # the admin. Nil means the worksheet isn't offered to international buyers.
  def price_in_usd
    return if price_in_cents.nil?

    dollars = price_in_cents / 100.0
    dollars == dollars.to_i ? dollars.to_i : dollars
  end

  def price_in_usd=(value)
    self.price_in_cents = value.present? ? (value.to_f * 100).round : nil
  end

  # PayPal Orders v2 wants the amount as a string like "4.99".
  def usd_amount_string
    return if price_in_cents.nil?

    format("%.2f", price_in_cents / 100.0)
  end

  private

  def worksheet_pdf_must_be_a_reasonable_pdf
    return unless worksheet_pdf.attached?

    unless worksheet_pdf.content_type == "application/pdf"
      errors.add(:worksheet_pdf, "must be a PDF file")
    end
    if worksheet_pdf.byte_size > MAX_PDF_BYTES
      errors.add(:worksheet_pdf, "must be 20 MB or smaller")
    end
  end
end
