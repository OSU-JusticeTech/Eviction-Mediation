ENV["RAILS_ENV"] ||= "test"
require "simplecov"

SimpleCov.start "rails"

require_relative "../config/environment"
require "rails/test_help"

if defined?(Prawn::Fonts::AFM)
  Prawn::Fonts::AFM.hide_m17n_warning = true
end

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

    def with_stubbed_twilio(send_ok:, verify_raises: false, verify_result: false, generated_code: 123456)
      fake = Object.new
      fake.define_singleton_method(:generate_code) { generated_code }
      fake.define_singleton_method(:send_verification_code) { |_phone, _code| send_ok }
      fake.define_singleton_method(:verify_code) do |_phone, _code|
        raise StandardError, "forced failure" if verify_raises

        verify_result
      end

      original_new = TwilioService.method(:new)
      TwilioService.define_singleton_method(:new) { fake }
      yield
    ensure
      TwilioService.define_singleton_method(:new) { |*args, &block| original_new.call(*args, &block) }
    end

    def with_env(vars)
      old = {}
      vars.each do |k, v|
        old[k] = ENV[k]
        ENV[k] = v
      end
      yield
    ensure
      vars.each_key { |k| ENV[k] = old[k] }
    end
  end
end
