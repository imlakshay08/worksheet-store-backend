class Order < ApplicationRecord
  belongs_to :product

  DOWNLOAD_LIMIT     = 5
  DOWNLOAD_VALID_FOR = 30.days

  scope :paid,    -> { where(status: "paid") }
  scope :pending, -> { where(status: "pending") }

  def amount_in_paise
    product&.price_in_paise.to_i
  end

  def amount_in_rupees
    amount_in_paise / 100.0
  end

  def full_address
    [address_line, city, state, postal_code, country].compact_blank.join(", ")
  end

  # Whether this order's download link is currently usable.
  def download_available?
    status == "paid" &&
      download_token.present? &&
      (download_token_expires_at.nil? || download_token_expires_at.future?) &&
      download_count.to_i < DOWNLOAD_LIMIT
  end

  # Generate a fresh, expiring download token if one isn't already present.
  def ensure_download_token!
    return if download_token.present?

    update!(
      download_token: SecureRandom.urlsafe_base64(32),
      download_token_expires_at: DOWNLOAD_VALID_FOR.from_now,
      download_count: 0
    )
  end

  # Sends the worksheet download email via Resend and records that it was sent.
  # Raises if delivery fails, so callers (webhook / admin) can react.
  def deliver_download_email!
    ensure_download_token!

    Resend::Emails.send(
      {
        from: "French Worksheet Hub <worksheets@frenchworksheethub.com>",
        to: email,
        subject: "Your worksheet: #{product.title}",
        html: "<p>Thanks for your purchase! Download your worksheet here:</p>" \
              "<p><a href=\"#{download_url}\">#{download_url}</a></p>" \
              "<p>This link is valid for 30 days.</p>"
      }
    )

    update!(download_email_sent_at: Time.current)
  end

  def download_url
    Rails.application.routes.url_helpers.download_order_url(
      id: download_token,
      host: ENV.fetch("APP_HOST", "localhost:3000")
    )
  end
end
