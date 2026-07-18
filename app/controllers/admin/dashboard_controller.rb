class Admin::DashboardController < Admin::BaseController
  def index
    # Revenue is split by currency and summed from each order's SNAPSHOTTED
    # amount (what was actually paid), so editing product prices never moves it.
    @inr_revenue_paise = Order.paid.where(currency: "INR").sum(:amount_cents)
    @usd_revenue_cents = Order.paid.where(currency: "USD").sum(:amount_cents)

    @orders_today     = Order.where("orders.created_at >= ?", Time.current.beginning_of_day).count
    @orders_this_week = Order.where("orders.created_at >= ?", Time.current.beginning_of_week).count

    @total_products  = Product.count
    @active_products = Product.where(active: true).count

    @recent_orders = Order.includes(:product, order_items: :product).order(created_at: :desc).limit(8)
  end
end
