require "application_system_test_case"

class MessagesIndexTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediator = users(:mediator1)
    @admin = users(:admin1)
  end

  test "messages index requires authentication" do
    visit messages_path

    assert_current_path login_path
    assert_text "You must be logged in"
  end

  test "tenant sees tenant negotiations page" do
    sign_in_as(@tenant)
    visit messages_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "Tenant Negotiation & Messages"
    assert_text "Welcome, #{@tenant.FName}!"
  end

  test "landlord sees landlord negotiations page" do
    sign_in_as(@landlord)
    visit messages_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "Landlord Negotiation & Messages"
    assert_text "Welcome, #{@landlord.FName}!"
  end

  test "mediator is redirected to assigned mediations page" do
    sign_in_as(@mediator)
    visit messages_path

    assert_current_path third_party_mediations_path
    assert_selector "h1", text: "Your Assigned Mediation Cases"
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