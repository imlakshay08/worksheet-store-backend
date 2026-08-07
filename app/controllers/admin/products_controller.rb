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
    @product = Product.new(product_attributes)

    if @product.save
      maybe_refresh_page_count(@product)
      redirect_to admin_products_path, notice: "Worksheet added successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @product.update(product_attributes)
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

  # Compress a freshly-uploaded PDF before it's attached (Canva exports are huge
  # and image-heavy). Everything downstream then stores/serves the smaller file.
  def product_attributes
    attrs = product_params
    attrs[:worksheet_pdf] = compress_pdf(attrs[:worksheet_pdf]) if attrs[:worksheet_pdf].present?
    attrs
  end

  # Shell out to Ghostscript to shrink the PDF. Returns the compressed file only
  # if it actually came out smaller; otherwise (or on any error, or on Windows/
  # dev where gs isn't present) it returns the original untouched — so this can
  # never block or crash an upload.
  def compress_pdf(uploaded)
    return uploaded if Gem.win_platform?
    return uploaded unless uploaded.respond_to?(:tempfile) && uploaded.content_type == "application/pdf"

    src = uploaded.tempfile.path
    out = Rails.root.join("tmp", "pdf-compress-#{SecureRandom.hex(8)}.pdf").to_s

    ok = system("timeout", "120", "gs",
                "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.4", "-dPDFSETTINGS=/ebook",
                "-dNOPAUSE", "-dQUIET", "-dBATCH", "-sOutputFile=#{out}", src,
                out: File::NULL, err: File::NULL)

    if ok && File.exist?(out) && File.size(out).positive? && File.size(out) < File.size(src)
      Rails.logger.info("PDF compressed #{File.size(src)} → #{File.size(out)} bytes")
      return { io: File.open(out), filename: uploaded.original_filename, content_type: "application/pdf" }
    end

    File.delete(out) if File.exist?(out)
    uploaded
  rescue => e
    Rails.logger.warn("PDF compression skipped: #{e.message}")
    uploaded
  end
end
