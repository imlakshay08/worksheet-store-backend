class OrdersController < ApplicationController
  def create
    product = Product.find_by(slug: params[:product_slug], active: true)

    if product.nil?
      render json: { error: "Product not found" }, status: :not_found
      return
    end

    order = Order.create!(
      email: params[:email],
      product: product,
      status: "pending"
    )

    razorpay_order = Razorpay::Order.create(
      "amount" => product.price_in_paise,
      "currency" => "INR",
      "receipt" => "order_#{order.id}",
      "notes" => { "internal_order_id" => order.id }
    )

    order.update!(razorpay_order_id: razorpay_order.id)

    render json: {
      order_id: order.id,
      razorpay_order_id: razorpay_order.id,
      razorpay_key_id: Rails.application.credentials.dig(:razorpay, :key_id),
      amount: product.price_in_paise,
      product_title: product.title
    }, status: :created
  end
  
  def show
    order = Order.find(params[:id])
    render json: {
      status: order.status,
      product_title: order.product.title
    }
  end
end