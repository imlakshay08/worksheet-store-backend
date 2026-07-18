class Order < ApplicationRecord
  include DownloadLinkHost

  # product_id is nullable: legacy/single-item orders keep a product; multi-item
  # cart orders don't have one single product — their worksheets live in
  # order_items. New code should read order_items, not #product.
  belongs_to :product, optional: true
  has_many :order_items, dependent: :destroy

  DOWNLOAD_LIMIT     = 5
  DOWNLOAD_VALID_FOR = 30.days

  scope :paid,     -> { where(status: "paid") }
  scope :pending,  -> { where(status: "pending") }
  scope :refunded, -> { where(status: "refunded") }

  # Customer-input validation. Presence of name/email/phone is enforced at the
  # checkout controller (so internal/webhook creates aren't affected); these
  # add format + length caps so no oversized or malformed data is ever stored,
  # emailed, or logged. allow_blank keeps optional fields optional.
  PHONE_FORMAT = /\A[0-9+\-()\s]+\z/

  # Validate customer input only at creation (checkout). Internal status updates
  # (e.g. the webhook marking an order paid) must never be blocked by these, so
  # an existing order with slightly-off legacy data can still be fulfilled.
  with_options on: :create, allow_blank: true do
    validates :email, length: { maximum: 150 }, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :name,         length: { maximum: 100 }
    validates :phone,        length: { maximum: 30 },
                             format: { with: PHONE_FORMAT, message: "is not a valid phone number" }
    validates :address_line, length: { maximum: 200 }
    validates :city,         length: { maximum: 100 }
    validates :state,        length: { maximum: 100 }
    validates :postal_code,  length: { maximum: 20 }
    validates :country,      length: { maximum: 60 }
  end

  def paypal?
    payment_provider == "paypal"
  end

  # ---- Display helpers (admin) -------------------------------------------

  # Titles of the worksheets on this order. Falls back to the legacy single
  # product for any pre-migration order without items (shouldn't happen post
  # backfill, but keeps the admin robust).
  def worksheet_titles
    titles = order_items.map { |item| item.product&.title }.compact
    titles.presence || [product&.title].compact
  end

  # Short label for order lists: the title if there's one worksheet, else a count.
  def worksheets_summary
    titles = worksheet_titles
    titles.size <= 1 ? (titles.first || "—") : "#{titles.size} worksheets"
  end

  # ---- Money -------------------------------------------------------------
  # `amount_cents` + `currency` are SNAPSHOTTED at checkout: the exact amount
  # the customer actually paid, frozen forever. Never recompute from the
  # product's current price (which can change later). Minor units = paise for
  # INR, cents for USD.

  # Formatted amount in the currency the customer actually paid in.
  def display_amount
    major = amount_cents.to_i / 100.0
    if currency == "USD"
      format("$%.2f", major)
    else
      "₹" + (major == major.to_i ? major.to_i.to_s : format("%.2f", major))
    end
  end

  # Expected captured amount, for payment-verification (defence in depth).
  def expected_amount_minor          # Razorpay reports paise as an integer
    amount_cents.to_i
  end

  def expected_amount_decimal_string # PayPal reports e.g. "1.00"
    format("%.2f", amount_cents.to_i / 100.0)
  end

  def full_address
    [address_line, city, state, postal_code, country].compact_blank.join(", ")
  end

  # Mark a paid order as refunded. Because item download_available? requires the
  # order status == "paid", this immediately revokes every download link.
  def mark_refunded!
    update!(status: "refunded")
  end

  # Sends the worksheet download email via Resend and records that it was sent.
  # Generates a token per worksheet, then lists them all in one email.
  # Raises if delivery fails, so callers (webhook / admin) can react.
  def deliver_download_email!
    items = order_items.includes(:product).to_a
    items.each(&:ensure_download_token!)

    Resend::Emails.send(
      {
        from: "French Worksheet Hub <worksheets@frenchworksheethub.com>",
        to: email,
        reply_to: "frenchworksheethub@gmail.com",
        subject: email_subject(items),
        html: download_email_html(items),
        text: download_email_text(items)
      }
    )

    update!(download_email_sent_at: Time.current)
  end

  private

  def email_subject(items)
    if items.size == 1
      "Your worksheet is ready: #{items.first.product.title}"
    else
      "Your #{items.size} worksheets are ready"
    end
  end

  def first_name
    name.to_s.strip.split(/\s+/).first
  end

  def download_email_text(items)
    greeting = first_name.present? ? "Bonjour #{first_name}," : "Bonjour,"
    intro    = items.size == 1 ? "Your worksheet is ready:" : "Your #{items.size} worksheets are ready:"

    blocks = items.map do |item|
      <<~ITEM.strip
        #{item.product.title}
        #{item.download_url}
      ITEM
    end.join("\n\n")

    <<~TEXT
      #{greeting}

      Thank you for your purchase! #{intro}

      #{blocks}

      Each link is valid for 30 days. Please save your PDFs after downloading.

      Need help? Didn't get everything, or having trouble opening a PDF?
      Just reply to this email and we'll sort it out.

      Merci,
      Nidhi Tyagi — French Worksheet Hub

      Most worksheets train memory. Mine train thinking.
    TEXT
  end

  def download_email_html(items)
    esc      = ->(value) { ERB::Util.html_escape(value.to_s) }
    greeting = first_name.present? ? "Bonjour #{esc.call(first_name)}," : "Bonjour,"
    heading  = items.size == 1 ? "Merci! Your worksheet is ready." : "Merci! Your worksheets are ready."
    intro    = items.size == 1 ? "Your printable PDF — complete with practice exercises and a full answer key — is ready to download below." : "Your printable PDFs — each complete with practice exercises and a full answer key — are ready to download below."
    item_blocks = items.map { |item| download_email_item_block(item, esc) }.join

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
                    <h1 style="margin:0 0 10px 0; font-family:Georgia,'Times New Roman',serif; font-size:24px; line-height:1.25; color:#1f2a3c;">#{heading}</h1>
                    <p style="margin:0 0 22px 0; font-family:Arial,Helvetica,sans-serif; font-size:15px; line-height:1.6; color:#5b6478;">Thank you for your purchase. #{intro}</p>
                  </td>
                </tr>

                <!-- one card + download button per worksheet -->
                #{item_blocks}

                <!-- validity note -->
                <tr>
                  <td style="padding:2px 36px 28px 36px;">
                    <p style="margin:0; font-family:Arial,Helvetica,sans-serif; font-size:12px; color:#5b6478;">🔒 Each link is valid for 30 days and can be used a few times — please save your PDFs after downloading.</p>
                  </td>
                </tr>

                <!-- support -->
                <tr>
                  <td style="padding:0 36px 26px 36px;">
                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #ece4d3;">
                      <tr>
                        <td style="padding-top:16px; font-family:Arial,Helvetica,sans-serif; font-size:13px; line-height:1.6; color:#5b6478;">
                          <strong style="color:#1f2a3c;">Need help?</strong> Didn't get everything, or having trouble opening the PDF?
                          Just reply to this email — we'll sort it out quickly.
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

              <p style="margin:18px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:11px; color:#8b8472;">You received this email because you purchased worksheets from French Worksheet Hub.</p>

            </td>
          </tr>
        </table>
      </body>
      </html>
    HTML
  end

  # One worksheet's card + download button + fallback link, as email table rows.
  def download_email_item_block(item, esc)
    url   = esc.call(item.download_url)
    title = esc.call(item.product.title)

    <<~HTML
      <tr>
        <td style="padding:0 36px 6px 36px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#faf6ee; border:1px solid #ece4d3; border-radius:12px;">
            <tr>
              <td style="padding:18px 22px;">
                <div style="font-family:Arial,Helvetica,sans-serif; font-size:11px; letter-spacing:2px; text-transform:uppercase; color:#5b6478;">Your worksheet</div>
                <div style="font-family:Georgia,'Times New Roman',serif; font-size:18px; font-weight:bold; color:#1f2a3c; margin-top:4px;">#{title}</div>
                <table role="presentation" cellpadding="0" cellspacing="0" style="margin-top:14px;">
                  <tr>
                    <td style="border-radius:999px; background-color:#c1432e;">
                      <a href="#{url}" style="display:inline-block; color:#ffffff; text-decoration:none; font-family:Arial,Helvetica,sans-serif; font-size:15px; font-weight:bold; padding:12px 30px; border-radius:999px;">Download PDF</a>
                    </td>
                  </tr>
                </table>
                <p style="margin:12px 0 0 0; font-family:Arial,Helvetica,sans-serif; font-size:11px; color:#8b8472; word-break:break-all;">Button not working? Copy this link: <a href="#{url}" style="color:#c1432e;">#{url}</a></p>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    HTML
  end
end
