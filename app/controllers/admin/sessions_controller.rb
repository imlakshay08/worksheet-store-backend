class Admin::SessionsController < Admin::BaseController
  layout "admin_auth"
  skip_before_action :require_login, only: [:new, :create]

  ADMIN_USERNAME = "nidhi".freeze

  # Local-only password, used ONLY when there is no admin password in the
  # encrypted credentials — i.e. when someone has cloned this repo without the
  # master key and wants to look around with `bin/rails db:setup`.
  #
  # Production is untouched by this: there, a missing credential still fails
  # closed (see .expected_password). Never ship a deploy running in development.
  DEMO_PASSWORD = "worksheet-demo".freeze

  # The password to check against. Real credentials always win; the demo
  # password only ever applies on a local machine with no credentials at all.
  def self.expected_password
    from_credentials = Rails.application.credentials.dig(:admin, :password).to_s
    return from_credentials if from_credentials.present?

    Rails.env.local? ? DEMO_PASSWORD : ""
  end

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
    expected = self.class.expected_password
    return false if expected.blank?

    user_ok = ActiveSupport::SecurityUtils.secure_compare(username, ADMIN_USERNAME)
    pass_ok = ActiveSupport::SecurityUtils.secure_compare(password, expected)
    user_ok && pass_ok
  end
end
