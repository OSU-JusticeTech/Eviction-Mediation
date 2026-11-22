require "application_system_test_case"

# System tests for the public (unauthenticated) landing page, which is the
# application root, and the standalone FAQ page it links to.
class ResourcesLandingTest < ApplicationSystemTestCase
  test "unauthenticated visitor sees the public landing page at root" do
    visit root_path

    assert_text "Resolve rental disputes"
    assert_text "A chat-based mediation tool for tenants and landlords."
    assert_link "Log In"
    assert_link "Create a Free Account"
  end

  test "footer opens public terms and shows the disclaimer without leaving the page" do
    visit root_path
    within(".site-footer") { click_link "Terms of Use" }
    assert_current_path terms_of_use_path
    assert_no_button "I Agree", disabled: :all

    within(".site-footer") { click_button "Legal Disclaimer" }
    assert_selector "#site-legal-disclaimer[open] h2", text: "Legal Disclaimer"
    assert_current_path terms_of_use_path
    within("#site-legal-disclaimer") { click_button "Close" }
    assert_no_selector "#site-legal-disclaimer[open]"
    assert_current_path terms_of_use_path
  end

  test "log in and sign up links navigate to the right pages" do
    visit root_path
    click_link "Create a Free Account", match: :first
    assert_current_path signup_path

    visit root_path
    click_link "Log In", match: :first
    assert_current_path login_path
  end

  test "landing page previews the most common questions" do
    visit root_path

    assert_text "Common questions"
    assert_text "Why should I try negotiation or mediation?"
    assert_text "What happens if we reach an agreement?"
    assert_selector "summary", text: "What is the difference between negotiation and mediation?", minimum: 1
  end

  test "visitor can expand a previewed question to read its answer" do
    visit root_path

    # Each preview is a <details>, so the answer stays collapsed until clicked.
    assert_no_text "Going to court can take time"
    find("summary", text: "Why should I try negotiation or mediation?").click
    assert_text "Going to court can take time"
  end

  test "visitor can open the full FAQ page and return to the landing page" do
    visit root_path

    click_link "See all FAQs"
    assert_current_path faqs_path
    assert_text "Frequently Asked Questions"

    click_link "Back"
    assert_current_path root_path
    assert_text "Resolve rental disputes"
  end

  test "visitor can view the negotiation guide and return" do
    visit resources_path(tab: "negotiation")

    assert_text "Negotiation & Mediation: What They Are and How They Can Help"

    click_link "Back"
    assert_current_path root_path
    assert_text "Resolve rental disputes"
  end
end
