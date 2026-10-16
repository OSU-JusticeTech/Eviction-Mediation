require "application_system_test_case"

class ResourcesTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
  end

  test "tenant sees the FAQs on the guide tab without the resources guide" do
    sign_in_as(@tenant)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    assert_text "Frequently Asked Questions"
    assert_text "Q: What is Mediation?"
    assert_no_text "Tenant Resources"
    assert_no_css ".resx-card"
  end

  test "landlord sees the FAQs on the guide tab without the resources guide" do
    sign_in_as(@landlord)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    assert_text "Frequently Asked Questions"
    assert_text "Q: What is Mediation?"
    assert_no_text "Landlord Resources"
    assert_no_css ".resx-card"
  end

  test "FAQ accordion item reveals its answer when opened" do
    sign_in_as(@tenant)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    assert_no_text "neutral person called a"
    find(".accordion-header", text: "What is Mediation?").click
    assert_text "neutral person called a"
  end

  test "FAQ category tabs switch the listed questions" do
    sign_in_as(@landlord)
    visit resources_path(tab: "guide")
    dismiss_terms_modal_if_present

    click_link "Data Privacy"
    assert_text "Q: Who operates this platform?"
    assert_no_text "Q: How does this tool work?"
  end

  test "navbar resources link opens the resources page" do
    sign_in_as(@tenant)
    visit dashboard_path
    dismiss_terms_modal_if_present

    click_link "Resources"
    assert_current_path resources_path
    assert_text "Frequently Asked Questions"
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
