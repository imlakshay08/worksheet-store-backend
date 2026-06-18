class DownloadsController < ApplicationController
  def show
    order = Order.find_by(download_token: params[:id], status: "paid")

    if order.nil?
      render plain: "Invalid or expired download link.", status: :not_found
      return
    end

    redirect_to order.product.worksheet_pdf.url, allow_other_host: true
  end
end