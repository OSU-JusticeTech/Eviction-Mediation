require "application_system_test_case"

# System tests for the public (unauthenticated) resources landing page,
# which is now the application root.
class ResourcesLandingTest < ApplicationSystemTestCase
  test "unauthenticated visitor sees the public landing page at root" do
    visit root_path

    assert_text "Resolve rental disputes"
    assert_text "Understand your rights and options"
    assert_link "Log In"
    assert_link "Create a Free Account"
  end

  test "log in and sign up links navigate to the right pages" do
    visit root_path
    click_link "Create a Free Account", match: :first
    assert_current_path signup_path

    visit root_path
    click_link "Log In", match: :first
    assert_current_path login_path
  end

  test "visitor can switch between tenant and landlord resources" do
    visit root_path

    # Tenant is the default selected role
    assert_text "I'm facing eviction"
    assert_no_text "Start a conversation"

    click_button "I'm a Landlord"

    assert_text "Start a conversation"
    assert_no_text "I'm facing eviction"
  end

  test "visitor can open a resource card to reveal its panel" do
    visit root_path

    # The "Other housing issues" panel is hidden until its card is clicked.
    assert_no_text "Security deposits"
    find(".resx-card", text: "Other housing issues").click
    assert_text "Security deposits"
  end

  test "visitor can view the FAQs tab and return to the landing page" do
    visit root_path

    click_link "FAQs"
    assert_current_path resources_path(tab: "faqs")
    assert_text "Frequently Asked Questions"

    click_link "Back to Resources"
    assert_current_path root_path
    assert_text "Resolve rental disputes"
  end

  test "visitor can view the negotiation guide tab and return" do
    visit root_path

    click_link "Negotiation & Mediation Guide"
    assert_current_path resources_path(tab: "negotiation")
    assert_text "Negotiation & Mediation: What They Are and How They Can Help"

    click_link "Back to Resources"
    assert_current_path root_path
  end
end
