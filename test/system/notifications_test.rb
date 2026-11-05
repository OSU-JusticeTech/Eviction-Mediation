require "application_system_test_case"

class NotificationsTest < ApplicationSystemTestCase
  test "bell remains visible after navigation and frame refreshes" do
    tenant = users(:tenant1)
    visit login_path
    fill_in "email", with: tenant.Email
    fill_in "password", with: "password"
    find("input[type='submit'][value='Log In']").click
    accept_terms_if_present

    assert_selector "#notification_menu .notification-bell"

    { "Messages" => messages_path, "Documents" => documents_path }.each do |label, path|
      within(".navbar-menu") { click_link label, exact: true }
      assert_current_path path
      assert_selector ".navbar-menu a.active[href='#{path}']"
      assert_selector "#notification_menu .notification-bell"

      # Exercise the same frame reload used by the 30-second polling timer.
      page.execute_script("const frame = document.getElementById('notification_menu'); frame.src = frame.dataset.notificationsMenuUrlValue")
      assert_selector "#notification_menu[complete] .notification-bell"
      page.execute_script("return document.getElementById('notification_menu').reload()")
      assert_selector "#notification_menu[complete] .notification-bell"
      find(".notification-bell").click
      assert_selector ".notification-dropdown", visible: true
      assert_link "View all notifications", href: notifications_path
      find(".notification-bell").click
    end
  end
end
