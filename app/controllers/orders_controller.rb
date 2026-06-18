class OrdersController < ApplicationController
  CUSTOMER_FIELDS = %i[name email phone address_line city state postal_code country].freeze
  REQUIRED_FIELDS = %i[name email phone].freeze

  def create
    product = Product.find_by(slug: params[:product_slug], active: true)

    if product.nil?
      render json: { error: "This worksheet isn't available right now." }, status: :not_found
      return
    end

    details = customer_params
    missing = REQUIRED_FIELDS.select { |field| details[field].blank? }
    if missing.any?
      render json: { error: "Please fill in: #{missing.map(&:to_s).join(', ')}." },
             status: :unprocessable_entity
      return
    end

    order = Order.create!(details.merge(product: product, status: "pending"))

    razorpay_order = Razorpay::Order.create(
      "amount"   => product.price_in_paise,
      "currency" => "INR",
      "receipt"  => "order_#{order.id}",
      "notes"    => {
        "internal_order_id" => order.id,
        "customer_name"     => order.name,
        "customer_phone"    => order.phone,
        "customer_city"     => order.city,
        "customer_country"  => order.country
      }
    )

    order.update!(razorpay_order_id: razorpay_order.id)

    render json: {
      order_id:          order.id,
      razorpay_order_id: razorpay_order.id,
      razorpay_key_id:   Rails.application.credentials.dig(:razorpay, :key_id),
      amount:            product.price_in_paise,
      product_title:     product.title
    }, status: :created
  end

  def show
    order = Order.find(params[:id])
    render json: {
      status: order.status,
      product_title: order.product.title
    }
  end

  private

  def customer_params
    params.permit(*CUSTOMER_FIELDS).to_h.symbolize_keys
  end
end
