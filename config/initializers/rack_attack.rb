# Rate limiting to protect public endpoints and the admin login from abuse.
# The Rack::Attack middleware is mounted automatically by its Railtie.
class Rack::Attack
  # Don't throttle inside the test suite (keeps tests deterministic).
  Rack::Attack.enabled = !Rails.env.test?

  # A per-process in-memory counter is sufficient for a single app instance.
  Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

  # Never throttle the Razorpay webhook — it retries and is signature-verified.
  safelist("allow razorpay webhook") do |req|
    req.path == "/webhooks/razorpay"
  end

  # Throttle order creation. A real buyer needs only a handful of attempts;
  # this stops scripted spam that would create junk orders + Razorpay orders.
  throttle("orders/ip", limit: 15, period: 10.minutes) do |req|
    req.ip if req.post? && req.path == "/orders"
  end

  # Brute-force protection on the admin login form, layered:
  #   - burst:     5 attempts / 20 seconds  (stops rapid-fire guessing)
  #   - sustained: 20 attempts / 10 minutes (stops slow, drawn-out guessing)
  throttle("admin-login/burst/ip", limit: 5, period: 20.seconds) do |req|
    req.ip if req.post? && req.path == "/admin/login"
  end

  throttle("admin-login/sustained/ip", limit: 20, period: 10.minutes) do |req|
    req.ip if req.post? && req.path == "/admin/login"
  end

  # Friendly JSON response when a client is throttled.
  self.throttled_responder = lambda do |request|
    match_data  = request.env["rack.attack.match_data"] || {}
    retry_after = (match_data[:period] || 60).to_s
    [
      429,
      { "Content-Type" => "application/json", "Retry-After" => retry_after },
      [{ error: "Too many requests. Please wait a moment and try again." }.to_json]
    ]
  end
end
