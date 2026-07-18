class OrderItem < ApplicationRecord
  include DownloadLinkHost

  belongs_to :order
  belongs_to :product

  validates :unit_amount_cents, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # A worksheet's download is unlocked by its own token. The download limits are
  # shared with the Order-level constants so there's a single source of truth.
  delegate :status, to: :order

  # Whether this item's download link is currently usable. Mirrors the old
  # order-level rule, but gated on the PARENT order's paid status.
  def download_available?
    status == "paid" &&
      download_token.present? &&
      (download_token_expires_at.nil? || download_token_expires_at.future?) &&
      download_count.to_i < Order::DOWNLOAD_LIMIT
  end

  # Generate a fresh, expiring download token if one isn't already present.
  def ensure_download_token!
    return if download_token.present?

    update!(
      download_token: SecureRandom.urlsafe_base64(32),
      download_token_expires_at: Order::DOWNLOAD_VALID_FOR.from_now,
      download_count: 0
    )
  end

  # Amount snapshot for this line, formatted in the order's currency.
  def display_amount
    major = unit_amount_cents.to_i / 100.0
    if order.currency == "USD"
      format("$%.2f", major)
    else
      "₹" + (major == major.to_i ? major.to_i.to_s : format("%.2f", major))
    end
  end

  def download_url
    Rails.application.routes.url_helpers.download_order_url(
      id: download_token,
      host: download_link_host,
      protocol: Rails.env.production? ? "https" : "http"
    )
  end
end
