require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Enable Capybara to run its own test server in test mode
  # This ensures system tests use the test database with fixtures
  Capybara.run_server = true
  Capybara.server_host = '0.0.0.0' # Bind to all interfaces so chrome container can reach it
  Capybara.server_port = 3001 # Use different port than development server

  remote_selenium = ENV["SELENIUM_REMOTE_URL"].present?
  # In docker compose one-off containers, `web` may not point to the same container running Puma.
  default_app_host = remote_selenium ? ENV.fetch("HOSTNAME", "web") : "127.0.0.1"
  app_host = ENV.fetch("CAPYBARA_APP_HOST", default_app_host)
  Capybara.app_host = "http://#{app_host}:#{Capybara.server_port}"

  browser_mode = ENV["SYSTEM_TEST_HEADLESS"] == "false" ? :chrome : :headless_chrome

  driven_by :selenium, using: browser_mode, screen_size: [ 1400, 1400 ], options: {
    browser: :remote,
    url: ENV.fetch("SELENIUM_REMOTE_URL", "http://chrome:4444")
  }
end
