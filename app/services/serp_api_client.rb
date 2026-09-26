# Minimal SerpApi client (https://serpapi.com/search-api).
#
# Same shape as PaypalClient: a hand-rolled Net::HTTP wrapper rather than a gem.
# SerpApi's own Ruby gem pulls in extra dependencies for what is, for us, one
# GET request with query params — and this app already owns the pattern.
#
# Read-only and completely isolated from the payment/webhook/download paths:
# nothing here touches an Order, a token, or money.
#
# Credentials live in Rails encrypted credentials under :serpapi —
#   serpapi:
#     api_key: ...
require "net/http"
require "json"

class SerpApiClient
  class Error < StandardError; end
  # Raised when no API key is configured, so callers can degrade to a
  # "set this up" message instead of showing an error.
  class NotConfigured < Error; end

  BASE_URL = "https://serpapi.com/search.json".freeze

  class << self
    def configured?
      api_key.present?
    end

    def api_key
      Rails.application.credentials.dig(:serpapi, :api_key)
    end

    # One SerpApi search. `engine` is any SerpApi engine id ("google",
    # "google_shopping", ...); `location` is a SerpApi canonical location
    # string ("India", "Delhi, India") and is omitted when nil.
    #
    # Returns the parsed JSON response as a Hash. Raises Error on transport
    # failure, a non-2xx response, or an `error` key in the body (SerpApi
    # reports "no results" and quota problems that way, sometimes with a 200).
    def search(query:, engine: "google", location: nil, **extra)
      raise NotConfigured, "SerpApi API key is not configured" unless configured?

      params = {
        engine:  engine,
        q:       query,
        hl:      "en",
        gl:      "in",
        api_key: api_key
      }
      params[:location] = location if location.present?
      params.merge!(extra)

      body = get(params)
      parsed = body.present? ? JSON.parse(body) : {}

      if parsed["error"].present?
        raise Error, "SerpApi #{engine} search failed: #{parsed['error']}"
      end

      parsed
    rescue JSON::ParserError => e
      raise Error, "SerpApi returned a non-JSON response: #{e.message}"
    end

    private

    def get(params)
      uri = URI(BASE_URL)
      uri.query = URI.encode_www_form(params)

      req = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"

      res = perform(uri, req)

      unless res.is_a?(Net::HTTPSuccess)
        # Never echo the request URI — it carries the API key.
        raise Error, "SerpApi request failed (#{res.code}): #{res.body.to_s[0, 500]}"
      end

      res.body
    end

    def perform(uri, req)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.request(req)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise Error, "SerpApi connection failed: #{e.message}"
    end
  end
end
