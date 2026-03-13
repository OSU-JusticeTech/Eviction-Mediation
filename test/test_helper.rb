ENV["RAILS_ENV"] ||= "test"
require "simplecov"

SimpleCov.start "rails"

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests sequentially; SQL Server doesn't support parallel truncate in our test setup.
    # parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # Global authentication helper for integration tests
    def log_in_as(user)
      post login_path, params: { email: user.Email, password: "password" }
    end
  end
end
