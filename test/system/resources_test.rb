require "application_system_test_case"

class ResourcesTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
  end

  test "tenant can view tenant resources guide tab" do
    sign_in_as(@tenant)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    assert_text "Tenant Resources"
    assert_text "Learn the eviction process"
  end

  test "landlord can view landlord resources guide tab" do
    sign_in_as(@landlord)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    assert_text "Landlord Resources"
    assert_text "Learn the process and how early communication can save time, fees, and turnover."
  end

  test "guide tab renders the FAQ accordion above the resources guide" do
    sign_in_as(@tenant)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    assert_text "Frequently Asked Questions"
    assert_text "Tenant Resources"
  end

  test "tenant can open a resource card to reveal its panel" do
    sign_in_as(@tenant)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    # The first card's panel is opened on load, so this one starts hidden.
    assert_no_text "Security deposits"
    find(".resx-card", text: "Other housing issues").click
    assert_text "Security deposits"
  end

  test "landlord can open a resource card to reveal its panel" do
    sign_in_as(@landlord)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    assert_no_text "I want to start a conversation with my tenant"
    find(".resx-card", text: "Start a conversation").click
    assert_text "I want to start a conversation with my tenant"
  end

  test "navbar resources link opens the resources page" do
    sign_in_as(@tenant)
    visit dashboard_path
    dismiss_terms_modal_if_present

    click_link "Resources"
    assert_current_path resources_path
    assert_text "Tenant Resources"
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
