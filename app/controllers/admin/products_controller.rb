class Admin::ProductsController < Admin::BaseController
  before_action :set_product, only: [:show, :edit, :update, :destroy, :free_storage]

  def index
    # Eager-load the attachments + blobs so the per-product file sizes in the
    # list don't trigger a query per row.
    @products = Product.with_attached_worksheet_pdf
                       .with_attached_preview_image
                       .order(created_at: :desc)
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
      redirect_to admin_products_path, notice: success_notice("Worksheet added successfully.")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @product.update(product_attributes)
      maybe_refresh_page_count(@product)
      redirect_to admin_products_path, notice: success_notice("Worksheet updated successfully.")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @product.destroy
      redirect_to admin_products_path, notice: "Worksheet deleted."
    else
      redirect_to admin_products_path,
                  alert: "Can't delete “#{@product.title}” — it has orders, which are kept for your sales records. " \
                         "To free its cloud storage instead, use “Free storage”."
    end
  end

  # Delete only the stored files (PDF + cover) to free R2 space, keeping the
  # product record + all orders/revenue intact.
  def free_storage
    freed = @product.stored_bytes
    @product.free_storage!
    redirect_to admin_products_path,
                notice: "Freed #{helpers.number_to_human_size(freed)} of storage from “#{@product.title}”. " \
                        "Its sales history and revenue are kept — it's now inactive."
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
    @optimizations = []
    attrs[:worksheet_pdf] = compress_pdf(attrs[:worksheet_pdf])   if attrs[:worksheet_pdf].present?
    attrs[:preview_image] = compress_image(attrs[:preview_image]) if attrs[:preview_image].present?
    attrs
  end

  # Appends any "X MB → Y MB" savings to the success flash so the admin can see
  # the optimization actually happened.
  def success_notice(base)
    return base if @optimizations.blank?
    "#{base} Optimized: #{@optimizations.join(', ')}."
  end

  def human_mb(bytes)
    mb = bytes / 1_048_576.0
    format(mb >= 10 ? "%.0f MB" : "%.1f MB", mb)
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
      (@optimizations ||= []) << "PDF #{human_mb(File.size(src))} → #{human_mb(File.size(out))}"
      return { io: File.open(out), filename: uploaded.original_filename, content_type: "application/pdf" }
    end

    File.delete(out) if File.exist?(out)
    uploaded
  rescue => e
    Rails.logger.warn("PDF compression skipped: #{e.message}")
    uploaded
  end

  # Shrink/normalize a preview image with ImageMagick: cap the dimensions and
  # re-encode as a quality-82 JPEG (page-1 previews don't need to be huge).
  # Same safety contract as compress_pdf — falls back to the original on any
  # problem, and is skipped on the Windows dev box.
  def compress_image(uploaded)
    return uploaded if Gem.win_platform?
    return uploaded unless uploaded.respond_to?(:tempfile) && uploaded.content_type.to_s.start_with?("image/")

    src = uploaded.tempfile.path
    out = Rails.root.join("tmp", "img-compress-#{SecureRandom.hex(8)}.jpg").to_s

    ok = system("timeout", "60", "convert", "#{src}[0]",
                "-background", "white", "-flatten",
                "-resize", "1600x1600>", "-strip", "-quality", "82", out,
                out: File::NULL, err: File::NULL)

    if ok && File.exist?(out) && File.size(out).positive? && File.size(out) < File.size(src)
      Rails.logger.info("Image compressed #{File.size(src)} → #{File.size(out)} bytes")
      (@optimizations ||= []) << "image #{human_mb(File.size(src))} → #{human_mb(File.size(out))}"
      base = File.basename(uploaded.original_filename.to_s, ".*").presence || "preview"
      return { io: File.open(out), filename: "#{base}.jpg", content_type: "image/jpeg" }
    end

    File.delete(out) if File.exist?(out)
    uploaded
  rescue => e
    Rails.logger.warn("Image compression skipped: #{e.message}")
    uploaded
  end
end
