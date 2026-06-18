class DownloadsController < ApplicationController
  def show
    order = Order.find_by(download_token: params[:id])

    if order.nil? || !order.download_available?
      render plain: "This download link is invalid, expired, or has reached its download limit. " \
                    "Please contact us if you need help.",
             status: :not_found
      return
    end

    order.increment!(:download_count)
    redirect_to order.product.worksheet_pdf.url, allow_other_host: true
  end
end
