class Admin::DashboardController < Admin::BaseController
  def index
    # Revenue is split by currency — Razorpay settles in INR, PayPal in USD.
    @inr_revenue_paise = Order.paid.where.not(payment_provider: "paypal")
                              .joins(:product).sum("products.price_in_paise")
    @usd_revenue_cents = Order.paid.where(payment_provider: "paypal")
                              .joins(:product).sum("products.price_in_cents")

    @orders_today     = Order.where("orders.created_at >= ?", Time.current.beginning_of_day).count
    @orders_this_week = Order.where("orders.created_at >= ?", Time.current.beginning_of_week).count

    @total_products  = Product.count
    @active_products = Product.where(active: true).count

    @recent_orders = Order.includes(:product).order(created_at: :desc).limit(8)
  end
end
