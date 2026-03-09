require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Container-only setup: browser runs in the chrome service and app runs in web service.
  Capybara.run_server = false
  Capybara.app_host = ENV.fetch("CAPYBARA_APP_HOST", "http://web:3000")

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: {
    browser: :remote,
    url: ENV.fetch("SELENIUM_REMOTE_URL")
  }
end
