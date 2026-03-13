require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Enable Capybara to run its own test server in test mode
  # This ensures system tests use the test database with fixtures
  Capybara.run_server = true
  Capybara.server_host = '0.0.0.0' # Bind to all interfaces so chrome container can reach it
  Capybara.server_port = 3001 # Use different port than development server
  Capybara.app_host = "http://web:3001" # Chrome connects to the test server on web:3001

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: {
    browser: :remote,
    url: ENV.fetch("SELENIUM_REMOTE_URL", "http://chrome:4444")
  }
end
