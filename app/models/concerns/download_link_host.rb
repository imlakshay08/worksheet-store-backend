# Shared host resolution for customer-facing download links. Prefer an explicit
# APP_HOST, then the domain Railway injects, and only fall back to localhost in
# local dev — so a missing/forgotten env var can NEVER ship a dead "localhost"
# link to a real customer.
module DownloadLinkHost
  private

  def download_link_host
    ENV["APP_HOST"].presence ||
      ENV["RAILWAY_PUBLIC_DOMAIN"].presence ||
      "localhost:3000"
  end
end
