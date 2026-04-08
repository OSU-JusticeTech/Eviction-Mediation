require "application_system_test_case"

class MediationsCreationTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @admin = users(:admin1)
  end

  test "new mediation page requires authentication" do
    visit new_mediation_path

    assert_current_path login_path
    assert_text "You must be logged in to access the mediations."
  end

  test "tenant can view new mediation form" do
    sign_in_as(@tenant)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "Request New Negotiation"
    assert_text "Select a landlord from the dropdown"
    assert_selector "select#landlord-select"
    assert_button "Request Negotiation"
  end

  test "landlord can view new mediation form" do
    sign_in_as(@landlord)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "Request New Negotiation"
    assert_text "Enter the tenant's email address"
    assert_selector "input#tenant-email"
    assert_button "Request Negotiation"
  end

  test "landlord can submit negotiation request for existing tenant" do
    sign_in_as(@landlord)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    fill_in "tenant-email", with: @tenant.Email
    click_button "Request Negotiation"

    assert_current_path messages_path
    assert_text "Negotiation request sent to #{@tenant.Email}"
  end

  test "tenant can submit negotiation request for existing landlord" do
    sign_in_as(@tenant)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    select @landlord.CompanyName, from: "landlord-select"
    click_button "Request Negotiation"

    assert_text "Negotiation requested with #{@landlord.CompanyName}"
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