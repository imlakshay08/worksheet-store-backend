class Admin::OrdersController < Admin::BaseController
  def index
    @orders = Order.includes(:product).order(created_at: :desc)
    @orders = @orders.where(status: params[:status]) if params[:status].present?
    if params[:email].present?
      @orders = @orders.where("orders.email ILIKE :q OR orders.name ILIKE :q", q: "%#{params[:email]}%")
    end
  end

  def show
    @order = Order.includes(:product).find(params[:id])
  end

  def resend_email
    order = Order.find(params[:id])

    if order.status != "paid"
      redirect_to admin_order_path(order), alert: "Can only resend the download email for paid orders."
      return
    end

    order.deliver_download_email!
    redirect_to admin_order_path(order), notice: "Download email re-sent to #{order.email}."
  rescue => e
    redirect_to admin_order_path(order), alert: "Could not send email: #{e.message}"
  end
end
