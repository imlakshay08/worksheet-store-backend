require "test_helper"

class Admin::SessionsControllerTest < ActionDispatch::IntegrationTest
  test "signs in with the configured password" do
    sign_in_admin
    assert_redirected_to admin_root_path

    get admin_root_path
    assert_response :success
  end

  test "rejects a wrong password" do
    post admin_login_path, params: { username: "nidhi", password: "not-the-password" }
    assert_response :unprocessable_entity

    get admin_root_path
    assert_redirected_to admin_login_path
  end

  test "rejects a wrong username even with the right password" do
    post admin_login_path, params: {
      username: "admin",
      password: Admin::SessionsController.expected_password
    }
    assert_response :unprocessable_entity
  end

  # The demo password exists so a reviewer can clone the repo without the master
  # key and still look around. It must never become a way into a real deploy.
  test "a missing admin credential fails closed outside local environments" do
    blank_credentials = Object.new
    def blank_credentials.dig(*) = nil

    Rails.application.stub(:credentials, blank_credentials) do
      Rails.env.stub(:local?, false) do
        assert_equal "", Admin::SessionsController.expected_password
      end

      Rails.env.stub(:local?, true) do
        assert_equal Admin::SessionsController::DEMO_PASSWORD,
                     Admin::SessionsController.expected_password
      end
    end
  end

  test "real credentials always win over the demo password" do
    real = Object.new
    def real.dig(*) = "a-real-password"

    Rails.application.stub(:credentials, real) do
      Rails.env.stub(:local?, true) do
        assert_equal "a-real-password", Admin::SessionsController.expected_password
      end
    end
  end

  test "signing out clears the session" do
    sign_in_admin
    delete admin_logout_path

    get admin_root_path
    assert_redirected_to admin_login_path
  end
end
