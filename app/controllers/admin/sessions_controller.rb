class Admin::SessionsController < Admin::BaseController
  layout "admin_auth"
  skip_before_action :require_login, only: [:new, :create]

  ADMIN_USERNAME = "nidhi".freeze

  def new
    redirect_to admin_root_path if admin_signed_in?
  end

  def create
    if valid_credentials?(params[:username].to_s.strip, params[:password].to_s)
      reset_session
      session[:admin_authenticated] = true
      redirect_to admin_root_path, notice: "Welcome back!"
    else
      flash.now[:alert] = "Invalid username or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to admin_login_path, notice: "You have been signed out."
  end

  private

  def valid_credentials?(username, password)
    expected_password = Rails.application.credentials.dig(:admin, :password).to_s
    return false if expected_password.blank?

    user_ok = ActiveSupport::SecurityUtils.secure_compare(username, ADMIN_USERNAME)
    pass_ok = ActiveSupport::SecurityUtils.secure_compare(password, expected_password)
    user_ok && pass_ok
  end
end
