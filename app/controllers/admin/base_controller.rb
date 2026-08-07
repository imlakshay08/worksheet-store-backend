class Admin::BaseController < ActionController::Base
  layout "admin"
  before_action :require_login

  # Turn any unhandled error into a friendly message instead of a raw 500 page,
  # so the admin always knows what happened. (Re-raised locally so real bugs
  # still surface during development.)
  rescue_from StandardError,                with: :handle_unexpected_error
  rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found

  helper_method :admin_signed_in?, :nav_link_class

  private

  def handle_not_found
    redirect_back fallback_location: admin_root_path, alert: "That record no longer exists."
  end

  def handle_unexpected_error(error)
    raise error if Rails.env.local?

    Rails.logger.error("[admin] #{error.class}: #{error.message}\n#{Array(error.backtrace).first(6).join("\n")}")
    redirect_back fallback_location: admin_root_path,
                  alert: "Something went wrong and your last action didn't finish — nothing was saved. " \
                         "Please try again. If it keeps happening, note what you were doing and contact support."
  end

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
