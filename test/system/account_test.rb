require "application_system_test_case"

class AccountTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @mediator = users(:mediator1)
  end

  test "account page requires authentication" do
    visit account_path

    assert_current_path login_path
    assert_text "You must be logged in to access the dashboard."
  end

  test "tenant can view account page and update address" do
    sign_in_as(@tenant)
    visit account_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "My Account"
    find("#user_AddressLine1").set("456 Updated St")
    find("#user_City").set("Columbus")
    find("#user_State").set("OH")
    find("#user_ZipCode").set("43210")
    click_button "Update Address"

    assert_current_path account_path
    assert_text "Address updated successfully."
    assert_text "456 Updated St, Columbus, OH 43210"
  end

  test "tenant can update password and sign in with the new password" do
    sign_in_as(@tenant)
    visit account_path
    dismiss_terms_modal_if_present

    fill_in "password", with: "NewPassword123!"
    fill_in "password_confirmation", with: "NewPassword123!"
    click_button "Update Password"

    assert_current_path account_path
    assert_text "Password updated successfully."

    visit logout_path
    assert_current_path root_path

    assert_selector "input[name='email']", wait: 5
    fill_in "email", with: @tenant.Email
    fill_in "password", with: "NewPassword123!"
    find("input[type='submit'][value='Log In']").click

    dismiss_terms_modal_if_present
    assert_current_path dashboard_path
  end

  test "mediator can update availability" do
    sign_in_as(@mediator)
    visit account_path

    assert_selector "h1", text: "My Account"
    check "availableCheckbox"
    click_button "Update Availability"

    assert_current_path account_path
    assert_text "Availability updated."
  end

  private

  def sign_in_as(user)
    visit login_path
    fill_in "email", with: user.Email
    fill_in "password", with: "password"
    click_button "Log In"
    dismiss_terms_modal_if_present
  end

  def dismiss_terms_modal_if_present
    return unless page.has_button?("OK", wait: 1)

    click_button "OK"
  end
end