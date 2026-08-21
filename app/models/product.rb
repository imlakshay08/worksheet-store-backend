class Product < ApplicationRecord
  has_one_attached :worksheet_pdf
  # A public page-1 preview image ("What's inside") shown to buyers before purchase.
  has_one_attached :preview_image
  has_many :orders,      dependent: :restrict_with_error
  has_many :order_items, dependent: :restrict_with_error

  # Soft delete: a "removed" product is hidden from the admin list but kept in
  # the DB so its orders/revenue stay intact. NOT a default_scope on purpose —
  # order.product must still resolve a removed product for order history.
  scope :listed, -> { where(removed_at: nil) }

  # Sold via either the legacy single-product order (orders.product_id) OR the
  # cart (order_items). Either means we must keep the record for its history.
  def sold?
    orders.exists? || order_items.exists?
  end

  MAX_PDF_BYTES = 40.megabytes
  MAX_PREVIEW_BYTES = 5.megabytes
  # pdf-reader is pure Ruby and can spike memory on very large PDFs — enough to
  # get the whole process killed on a small instance. Skip the page-count step
  # above this size so a big upload can never crash the app.
  PAGE_COUNT_MAX_BYTES = 15.megabytes

  before_validation :ensure_slug

  validates :title, presence: true, length: { maximum: 150 }
  validates :slug,  presence: true, length: { maximum: 100 },
                    format: { with: /\A[a-z0-9-]+\z/, message: "can only contain lowercase letters, numbers, and dashes" },
                    uniqueness: { case_sensitive: false }
  validates :description, length: { maximum: 8000 }, allow_blank: true
  validates :level,       length: { maximum: 40 },   allow_blank: true
  validate  :worksheet_pdf_must_be_a_reasonable_pdf
  validate  :preview_image_must_be_a_reasonable_image

  # Count the worksheet's pages from the uploaded PDF and cache it on the record.
  # Pure Ruby (pdf-reader) — no system dependencies. Called after a PDF upload.
  def refresh_page_count!
    return unless worksheet_pdf.attached? && has_attribute?(:page_count)
    return if worksheet_pdf.byte_size > PAGE_COUNT_MAX_BYTES

    count = worksheet_pdf.open { |file| PDF::Reader.new(file).page_count }
    update_column(:page_count, count)
  rescue => e
    Rails.logger.warn("Couldn't read page count for product #{id}: #{e.message}")
  end

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

  # Total R2 storage this worksheet occupies (PDF + cover image), in bytes.
  def stored_bytes
    bytes = 0
    bytes += worksheet_pdf.byte_size if worksheet_pdf.attached?
    bytes += preview_image.byte_size if preview_image.attached?
    bytes
  end

  def removed?
    removed_at.present?
  end

  # Permanently delete this worksheet's files from R2 to free the storage.
  # Records are untouched — revenue is snapshotted on orders, independent of it.
  def purge_files!
    worksheet_pdf.purge if worksheet_pdf.attached?
    preview_image.purge if preview_image.attached?
  end

  private

  def worksheet_pdf_must_be_a_reasonable_pdf
    return unless worksheet_pdf.attached?

    unless worksheet_pdf.content_type == "application/pdf"
      errors.add(:worksheet_pdf, "must be a PDF file")
    end
    if worksheet_pdf.byte_size > MAX_PDF_BYTES
      errors.add(:worksheet_pdf, "must be 40 MB or smaller")
    end
  end

  # Auto-generate a URL-safe slug from the title so the admin never has to think
  # about it. Only fills a blank slug — it never rewrites an existing one, which
  # would break live buy links.
  def ensure_slug
    return if slug.present?

    base = title.to_s.parameterize.presence || "worksheet"
    candidate = base
    n = 2
    while Product.where.not(id: id).exists?(slug: candidate)
      candidate = "#{base}-#{n}"
      n += 1
    end
    self.slug = candidate
  end

  def preview_image_must_be_a_reasonable_image
    return unless preview_image.attached?

    unless preview_image.content_type.to_s.start_with?("image/")
      errors.add(:preview_image, "must be an image (JPG or PNG)")
    end
    if preview_image.byte_size > MAX_PREVIEW_BYTES
      errors.add(:preview_image, "must be 5 MB or smaller")
    end
  end
end
