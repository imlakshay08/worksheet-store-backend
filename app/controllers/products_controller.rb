class ProductsController < ApplicationController
  def index
    products = Product.where(active: true).order(created_at: :desc)

    render json: products.map { |p|
      {
        title: p.title,
        description: p.description,
        # `level` is guarded so the storefront keeps working even if this code
        # deploys before the add_level_to_products migration has run.
        level: (p.level if p.has_attribute?(:level)),
        slug: p.slug,
        price: p.price_in_paise / 100.0,
        price_usd: p.price_in_usd
      }
    }
  end
end