class ProductsController < ApplicationController
  def index
    products = Product.where(active: true).order(created_at: :desc)

    render json: products.map { |p|
      {
        title: p.title,
        description: p.description,
        # `level`/`page_count` are guarded so the storefront keeps working even if
        # this code deploys before their migrations have run.
        level: (p.level if p.has_attribute?(:level)),
        slug: p.slug,
        price: p.price_in_paise / 100.0,
        price_usd: p.price_in_usd,
        page_count: (p.page_count if p.has_attribute?(:page_count)),
        preview_url: (p.preview_image.attached? ? "#{request.base_url}/products/#{p.slug}/preview" : nil)
      }
    }
  end

  # Public page-1 preview image ("What's inside"). Streams the curated image the
  # admin uploaded — never the actual worksheet PDF, which stays payment-gated.
  def preview
    product = Product.find_by(slug: params[:slug], active: true)
    unless product&.preview_image&.attached?
      head :not_found
      return
    end

    response.headers["Cache-Control"] = "public, max-age=3600"
    send_data product.preview_image.download,
              type: product.preview_image.content_type.presence || "image/jpeg",
              disposition: "inline"
  end
end