class Admin::ProductsController < Admin::BaseController
  before_action :set_product, only: [:show, :edit, :update, :destroy]

  def index
    @products = Product.all.order(created_at: :desc)
  end

  def show
  end

  def new
    @product = Product.new
  end

  def edit
  end

  def create
    @product = Product.new(product_params)

    if @product.save
      maybe_refresh_page_count(@product)
      redirect_to admin_products_path, notice: "Worksheet added successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @product.update(product_params)
      maybe_refresh_page_count(@product)
      redirect_to admin_products_path, notice: "Worksheet updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @product.destroy
      redirect_to admin_products_path, notice: "Worksheet deleted."
    else
      redirect_to admin_products_path, alert: @product.errors.full_messages.to_sentence
    end
  end

  private

  def set_product
    @product = Product.find(params[:id])
  end

  # Recompute the cached page count when a new PDF is uploaded, or backfill it
  # the first time an existing worksheet (with a PDF but no count) is saved.
  def maybe_refresh_page_count(product)
    uploaded = params.dig(:product, :worksheet_pdf).present?
    missing  = product.has_attribute?(:page_count) && product.page_count.blank? && product.worksheet_pdf.attached?
    product.refresh_page_count! if uploaded || missing
  end

  def product_params
    params.require(:product).permit(:title, :description, :level, :price_in_rupees, :price_in_usd, :slug, :active, :worksheet_pdf, :preview_image)
  end
end
