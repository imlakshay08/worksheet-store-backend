class Order < ApplicationRecord
  belongs_to :product

  def download_url
    Rails.application.routes.url_helpers.download_order_url(
      id: download_token,
      host: ENV.fetch("APP_HOST", "localhost:3000")
    )
  end
end