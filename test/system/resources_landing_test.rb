require "application_system_test_case"

# System tests for the public (unauthenticated) landing page, which is the
# application root, and the standalone FAQ page it links to.
class ResourcesLandingTest < ApplicationSystemTestCase
  test "unauthenticated visitor sees the public landing page at root" do
    visit root_path

    assert_text "Resolve rental disputes"
    assert_text "A text-based mediation tool for tenants and landlords."
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

  test "landing page previews the most common questions" do
    visit root_path

    assert_text "Common questions"
    assert_text "What is Mediation?"
    assert_text "How does this tool work?"
    assert_text "When can I use this tool?"
  end

  test "visitor can expand a previewed question to read its answer" do
    visit root_path

    # Each preview is a <details>, so the answer stays collapsed until clicked.
    assert_no_text "The mediator listens to both sides"
    find("summary", text: "What is Mediation?").click
    assert_text "The mediator listens to both sides"
  end

  test "visitor can open the full FAQ page and return to the landing page" do
    visit root_path

    click_link "See all FAQs"
    assert_current_path faqs_path
    assert_text "Frequently Asked Questions"

    click_link "Back to home"
    assert_current_path root_path
    assert_text "Resolve rental disputes"
  end

  test "visitor can view the negotiation guide and return" do
    visit resources_path(tab: "negotiation")

    assert_text "Negotiation & Mediation: What They Are and How They Can Help"

    click_link "Back to Resources"
    assert_current_path root_path
    assert_text "Resolve rental disputes"
  end
end
