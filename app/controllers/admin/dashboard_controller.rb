class Admin::DashboardController < Admin::BaseController
  def index
    @total_revenue_paise = Order.paid.joins(:product).sum("products.price_in_paise")

    @orders_today     = Order.where("orders.created_at >= ?", Time.current.beginning_of_day).count
    @orders_this_week = Order.where("orders.created_at >= ?", Time.current.beginning_of_week).count

    @total_products  = Product.count
    @active_products = Product.where(active: true).count

    @recent_orders = Order.includes(:product).order(created_at: :desc).limit(8)
  end
end
