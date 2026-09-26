ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    # Run serially on purpose. This suite stubs CLASS methods (SerpApiClient,
    # Razorpay, Resend) and a class is shared mutable state: with threaded
    # parallelism two tests stub and restore the same method at once and
    # corrupt it ("undefined method `__minitest_stub__api_key'"). Rails only
    # turns parallelism on past 50 tests, so this stayed hidden until the suite
    # grew past that — hence the explicit setting rather than a raised threshold.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  # Logs in as the admin using the password stored in credentials.
  def sign_in_admin
    post admin_login_path, params: {
      username: Admin::SessionsController::ADMIN_USERNAME,
      # Same source of truth as the controller, so the suite also runs for
      # someone who cloned the repo without the encrypted credentials.
      password: Admin::SessionsController.expected_password
    }
  end
end
