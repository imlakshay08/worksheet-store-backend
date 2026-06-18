require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  test "redirects to login when signed out" do
    get admin_root_path
    assert_redirected_to admin_login_path
  end

  test "renders the dashboard when signed in" do
    sign_in_admin
    get admin_root_path
    assert_response :success
  end
end
