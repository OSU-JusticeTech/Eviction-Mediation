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

  test "tenant can switch to faq and negotiation tabs" do
    sign_in_as(@tenant)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    click_link "FAQs"
    assert_current_path resources_path(tab: "faqs")
    assert_text "Frequently Asked Questions"

    click_link "Negotiation & Mediation"
    assert_current_path resources_path(tab: "negotiation")
    assert_text "Negotiation & Mediation: What They Are and How They Can Help"
  end

  test "landlord can view landlord resources guide tab" do
    sign_in_as(@landlord)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    assert_text "Landlord Resources"
    assert_text "Learn the process and how early communication can save time, fees, and turnover."
  end

  test "landlord can switch to faq and negotiation tabs" do
    sign_in_as(@landlord)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    click_link "FAQs"
    assert_current_path resources_path(tab: "faqs")
    assert_text "Frequently Asked Questions"

    click_link "Negotiation & Mediation"
    assert_current_path resources_path(tab: "negotiation")
    assert_text "Negotiation & Mediation: What They Are and How They Can Help"
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