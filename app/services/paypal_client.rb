# Minimal PayPal REST client (Orders v2 + webhook verification).
#
# We talk to the REST API directly with Net::HTTP rather than a gem: PayPal's
# official Ruby SDK (paypal-checkout-sdk) is deprecated and unmaintained, and
# our needs are tiny — get a token, create an order, capture it, verify a
# webhook signature.
#
# Credentials live in Rails encrypted credentials under :paypal —
#   paypal:
#     mode:          sandbox   # or "live"
#     client_id:     ...
#     client_secret: ...
#     webhook_id:    ...
require "net/http"
require "json"

class PaypalClient
  class Error < StandardError; end

  BASE_URLS = {
    "sandbox" => "https://api-m.sandbox.paypal.com",
    "live"    => "https://api-m.paypal.com"
  }.freeze

  class << self
    def configured?
      client_id.present? && client_secret.present?
    end

    def client_id
      cred(:client_id)
    end

    # Create a PayPal order for the given USD amount. `reference` and `custom_id`
    # let us tie the PayPal order back to our local Order in webhooks/captures.
    def create_order(reference:, custom_id:, amount:, currency: "USD", description: nil)
      body = {
        intent: "CAPTURE",
        purchase_units: [
          {
            reference_id: reference,
            custom_id:    custom_id,
            description:  description.to_s[0, 127].presence,
            amount:       { currency_code: currency, value: amount }
          }.compact
        ]
      }
      post("/v2/checkout/orders", body)
    end

    # Capture an approved PayPal order. Returns the parsed order resource;
    # the captured payment lives at purchase_units[0].payments.captures[0].
    def capture_order(paypal_order_id)
      post("/v2/checkout/orders/#{paypal_order_id}/capture", {})
    end

    # Ask PayPal to verify a webhook's signature. Returns true only on SUCCESS.
    def verify_webhook(headers:, body:)
      payload = {
        transmission_id:   headers["Paypal-Transmission-Id"],
        transmission_time: headers["Paypal-Transmission-Time"],
        cert_url:          headers["Paypal-Cert-Url"],
        auth_algo:         headers["Paypal-Auth-Algo"],
        transmission_sig:  headers["Paypal-Transmission-Sig"],
        webhook_id:        cred(:webhook_id),
        webhook_event:     body
      }
      result = post("/v1/notifications/verify-webhook-signature", payload)
      result["verification_status"] == "SUCCESS"
    end

    private

    def cred(key)
      Rails.application.credentials.dig(:paypal, key)
    end

    def client_secret
      cred(:client_secret)
    end

    def base_url
      mode = cred(:mode).to_s.presence || "sandbox"
      BASE_URLS.fetch(mode) { raise Error, "Invalid PayPal mode: #{mode.inspect}" }
    end

    # OAuth2 client-credentials token. Cached just under PayPal's ~9h lifetime.
    def access_token
      Rails.cache.fetch("paypal_access_token", expires_in: 8.hours) do
        uri = URI("#{base_url}/v1/oauth2/token")
        req = Net::HTTP::Post.new(uri)
        req.basic_auth(client_id, client_secret)
        req["Content-Type"] = "application/x-www-form-urlencoded"
        req.body = "grant_type=client_credentials"

        res = perform(uri, req)
        JSON.parse(res.body).fetch("access_token")
      end
    end

    def post(path, body)
      uri = URI("#{base_url}#{path}")
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{access_token}"
      req["Content-Type"]  = "application/json"
      req.body = body.to_json

      res    = perform(uri, req)
      parsed = res.body.present? ? JSON.parse(res.body) : {}

      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "PayPal #{path} failed (#{res.code}): #{res.body}"
      end

      parsed
    end

    def perform(uri, req)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.request(req)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise Error, "PayPal connection failed: #{e.message}"
    end
  end
end
