class Order < ApplicationRecord
  belongs_to :product

  DOWNLOAD_LIMIT     = 5
  DOWNLOAD_VALID_FOR = 30.days

  scope :paid,     -> { where(status: "paid") }
  scope :pending,  -> { where(status: "pending") }
  scope :refunded, -> { where(status: "refunded") }

  def amount_in_paise
    product&.price_in_paise.to_i
  end

  def amount_in_rupees
    amount_in_paise / 100.0
  end

  # Expected international amount, in USD cents — used to flag PayPal mismatches.
  def amount_in_cents
    product&.price_in_cents.to_i
  end

  def paypal?
    payment_provider == "paypal"
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

  # Mark a paid order as refunded. Because download_available? requires
  # status == "paid", this immediately revokes the customer's download link.
  def mark_refunded!
    update!(status: "refunded")
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
        reply_to: "nidhityagi2291@gmail.com",
        subject: "Your worksheet is ready: #{product.title}",
        html: download_email_html,
        text: download_email_text
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

  private

  def first_name
    name.to_s.strip.split(/\s+/).first
  end

  def download_email_text
    greeting = first_name.present? ? "Bonjour #{first_name}," : "Bonjour,"
    <<~TEXT
      #{greeting}

      Thank you for your purchase! Your worksheet is ready:

      #{product.title}

      Download it here (link valid for 30 days):
      #{download_url}

      Need help? Didn't get everything, or having trouble opening the PDF?
      Message us on WhatsApp: https://wa.me/918851137555
      or just reply to this email and we'll sort it out.

      Merci,
      Nidhi Tyagi — French Worksheet Hub

      Most worksheets train memory. Mine train thinking.
    TEXT
  end

  def download_email_html
    esc       = ->(value) { ERB::Util.html_escape(value.to_s) }
    greeting  = first_name.present? ? "Bonjour #{esc.call(first_name)}," : "Bonjour,"
    url       = esc.call(download_url)
    title     = esc.call(product.title)

    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light only">
      </head>
      <body style="margin:0; padding:0; background-color:#f1e9d8;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f1e9d8;">
          <tr>
            <td align="center" style="padding:32px 16px;">

              <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="width:560px; max-width:100%; background-color:#ffffff; border-radius:16px; overflow:hidden; box-shadow:0 12px 30px rgba(31,42,60,0.12);">

                <!-- accent bar -->
                <tr><td style="height:6px; background-color:#c1432e; font-size:0; line-height:0;">&nbsp;</td></tr>

                <!-- header -->
                <tr>
                  <td style="padding:28px 36px 8px 36px;">
                    <table role="presentation" cellpadding="0" cellspacing="0">
                      <tr>
                        <td style="width:46px; vertical-align:middle;">
                          <table role="presentation" cellpadding="0" cellspacing="0">
                            <tr>
                              <td align="center" valign="middle" style="width:42px; height:42px; border:2px solid #1f2a3c; border-radius:50%; font-family:Georgia,'Times New Roman',serif; font-weight:bold; font-size:14px; color:#1f2a3c;">NT</td>
                            </tr>
                          </table>
                        </td>
                        <td style="padding-left:12px; vertical-align:middle;">
                          <div style="font-family:Georgia,'Times New Roman',serif; font-size:18px; font-weight:bold; color:#1f2a3c; line-height:1.2;">French Worksheet Hub</div>
                          <div style="font-family:Arial,Helvetica,sans-serif; font-size:11px; letter-spacing:2px; text-transform:uppercase; color:#5b6478;">by Nidhi Tyagi</div>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>

                <!-- body -->
                <tr>
                  <td style="padding:20px 36px 8px 36px;">
                    <p style="margin:0 0 14px 0; font-family:Arial,Helvetica,sans-serif; font-size:16px; color:#1f2a3c;">#{greeting}</p>
                    <h1 style="margin:0 0 10px 0; font-family:Georgia,'Times New Roman',serif; font-size:24px; line-height:1.25; color:#1f2a3c;">Merci! Your worksheet is ready.</h1>
                    <p style="margin:0 0 22px 0; font-family:Arial,Helvetica,sans-serif; font-size:15px; line-height:1.6; color:#5b6478;">Thank you for your purchase. Your printable PDF — complete with practice exercises and a full answer key — is ready to download below.</p>
                  </td>
                </tr>

                <!-- product card -->
                <tr>
                  <td style="padding:0 36px;">
                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#faf6ee; border:1px solid #ece4d3; border-radius:12px;">
                      <tr>
                        <td style="padding:18px 22px;">
                          <div style="font-family:Arial,Helvetica,sans-serif; font-size:11px; letter-spacing:2px; text-transform:uppercase; color:#5b6478;">Your worksheet</div>
                          <div style="font-family:Georgia,'Times New Roman',serif; font-size:18px; font-weight:bold; color:#1f2a3c; margin-top:4px;">#{title}</div>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>

                <!-- CTA button -->
                <tr>
                  <td align="center" style="padding:28px 36px 10px 36px;">
                    <a href="#{url}" style="display:inline-block; background-color:#c1432e; color:#ffffff; text-decoration:none; font-family:Arial,Helvetica,sans-serif; font-size:16px; font-weight:bold; padding:15px 38px; border-radius:999px;">Download your worksheet</a>
                  </td>
                </tr>

                <!-- fallback link + validity -->
                <tr>
                  <td style="padding:6px 36px 28px 36px;">
                    <p style="margin:0 0 6px 0; font-family:Arial,Helvetica,sans-serif; font-size:12px; color:#5b6478;">Button not working? Copy and paste this link into your browser:</p>
                    <p style="margin:0 0 16px 0; font-family:Arial,Helvetica,sans-serif; font-size:12px; word-break:break-all;"><a href="#{url}" style="color:#c1432e;">#{url}</a></p>
                    <p style="margin:0; font-family:Arial,Helvetica,sans-serif; font-size:12px; color:#5b6478;">🔒 This link is valid for 30 days and can be used a few times — please save your PDF after downloading.</p>
                  </td>
                </tr>

                <!-- support -->
                <tr>
                  <td style="padding:0 36px 26px 36px;">
                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #ece4d3;">
                      <tr>
                        <td style="padding-top:16px; font-family:Arial,Helvetica,sans-serif; font-size:13px; line-height:1.6; color:#5b6478;">
                          <strong style="color:#1f2a3c;">Need help?</strong> Didn't get everything, or having trouble opening the PDF?
                          <a href="https://wa.me/918851137555" style="color:#c1432e;">Message us on WhatsApp</a>
                          or just reply to this email — we'll sort it out quickly.
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>

                <!-- footer -->
                <tr>
                  <td style="padding:22px 36px; background-color:#1f2a3c;">
                    <p style="margin:0 0 6px 0; font-family:Georgia,'Times New Roman',serif; font-size:15px; color:#ffffff;">Most worksheets train memory. Mine train thinking.</p>
                    <p style="margin:0; font-family:Arial,Helvetica,sans-serif; font-size:12px; color:#aab0c0;">
                      French Worksheet Hub · New Delhi, India ·
                      <a href="https://instagram.com/frenchworksheethub" style="color:#ecbcb1;">@frenchworksheethub</a>
                    </p>
                  </td>
                </tr>

              </table>

              <p style="margin:18px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:11px; color:#8b8472;">You received this email because you purchased a worksheet from French Worksheet Hub.</p>

            </td>
          </tr>
        </table>
      </body>
      </html>
    HTML
  end
end
