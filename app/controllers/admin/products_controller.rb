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
      redirect_to admin_products_path, notice: "Worksheet added successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @product.update(product_params)
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

  def product_params
    params.require(:product).permit(:title, :description, :price_in_paise, :slug, :active, :worksheet_pdf)
  end
end
