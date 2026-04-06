require "application_system_test_case"

class MediatorCasesTest < ApplicationSystemTestCase
  setup do
    @mediator = users(:mediator1)
    @other_mediator = users(:mediator2)
    @tenant = users(:tenant1)
    @assigned_case = primary_message_groups(:one)
  end

  test "mediator can view assigned case details" do
    sign_in_as(@mediator)
    visit mediator_case_path(@assigned_case)

    assert_selector "h1", text: "Mediation Case Details"
    assert_text @tenant.Email
    assert_link "Open Chat"
  end

  test "mediator cannot view case not assigned to them" do
    sign_in_as(@other_mediator)
    visit mediator_case_path(@assigned_case)

    assert_current_path third_party_mediations_path
    assert_text "You are no longer assigned to this mediation."
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