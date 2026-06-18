class Admin::BaseController < ActionController::Base
  layout "admin"
  before_action :require_login

  helper_method :admin_signed_in?, :nav_link_class

  private

  def admin_signed_in?
    session[:admin_authenticated] == true
  end

  def require_login
    return if admin_signed_in?
    redirect_to admin_login_path, alert: "Please sign in to continue."
  end

  def nav_link_class(active)
    base = "block px-3 py-2 rounded-md text-sm font-medium "
    base + (active ? "bg-gray-800 text-white" : "text-gray-300 hover:bg-gray-800 hover:text-white")
  end
end
