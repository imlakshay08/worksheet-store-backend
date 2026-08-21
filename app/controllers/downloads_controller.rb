class DownloadsController < ApplicationController
  def show
    item = OrderItem.find_by(download_token: params[:id])

    if item.nil? || !item.download_available?
      render plain: "This download link is invalid, expired, or has reached its download limit. " \
                    "Please contact us if you need help.",
             status: :not_found
      return
    end

    # The worksheet's file may have been removed to free storage after the sale.
    unless item.product&.worksheet_pdf&.attached?
      render plain: "This worksheet is no longer available for download. " \
                    "Please contact us and we'll help you out.",
             status: :not_found
      return
    end

    item.increment!(:download_count)

    # R2 (production) returns absolute, presigned URLs and ignores this. The
    # local Disk service (dev/test) needs a host to build the URL — take it from
    # the current request.
    ActiveStorage::Current.url_options ||= { protocol: request.protocol, host: request.host, port: request.optional_port }

    redirect_to item.product.worksheet_pdf.url, allow_other_host: true
  end
end
