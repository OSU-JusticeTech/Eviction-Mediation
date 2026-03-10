require "application_system_test_case"

class ThirdPartyMediationsTest < ApplicationSystemTestCase
  setup do
    @mediator = users(:mediator1)
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
  end

  test "third party mediations page requires authentication" do
    visit third_party_mediations_path

    assert_current_path login_path
    assert_text "You must be logged in to access the dashboard."
  end

  test "mediator can view assigned mediation cases" do
    sign_in_as(@mediator)
    visit third_party_mediations_path

    assert_selector "h1", text: "Your Assigned Mediation Cases"
    assert_text @tenant.FName
    assert_text @landlord.FName
    assert_link "View Mediation"
  end

  test "non mediator is denied third party mediations access" do
    sign_in_as(@tenant)
    visit third_party_mediations_path

    assert_current_path dashboard_path
    assert_text "Access Denied"
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