class ProductsController < ApplicationController
  def index
    products = Product.where(active: true).order(created_at: :desc)

    render json: products.map { |p|
      {
        title: p.title,
        description: p.description,
        slug: p.slug,
        price: p.price_in_paise / 100.0,
        price_usd: p.price_in_usd
      }
    }
  end
end