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

  # Reconciliation for the rare case where the webhook never arrived.
  # We never just trust the click — we ask Razorpay whether the order is
  # actually paid before marking it and delivering the worksheet.
  def fulfill
    order = Order.find(params[:id])

    if order.status == "paid"
      redirect_to admin_order_path(order), notice: "This order is already marked paid."
      return
    end

    if order.razorpay_order_id.blank?
      redirect_to admin_order_path(order), alert: "This order has no Razorpay order ID to verify."
      return
    end

    rzp_order = Razorpay::Order.fetch(order.razorpay_order_id)

    if rzp_order.status == "paid"
      captured = rzp_order.payments.items.find { |p| p.status == "captured" }
      order.update!(status: "paid", razorpay_payment_id: captured&.id)
      order.deliver_download_email!
      redirect_to admin_order_path(order),
                  notice: "Verified paid with Razorpay — order fulfilled and email sent to #{order.email}."
    else
      redirect_to admin_order_path(order),
                  alert: "Razorpay reports this order as '#{rzp_order.status}', not paid. Nothing was changed."
    end
  rescue => e
    redirect_to admin_order_path(order), alert: "Could not verify with Razorpay: #{e.message}"
  end
end
