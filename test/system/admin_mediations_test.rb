require "application_system_test_case"

class AdminMediationsTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin1)
    @mediator = users(:mediator1)
    @tenant = users(:tenant1)
    @mediation = primary_message_groups(:one)
    @message_string = message_strings(:one)

    # Ensure the case is an active, assigned, non-flagged mediation
    @mediation.update!(
      MediatorRequested: true,
      MediatorAssigned: true,
      MediatorID: @mediator.UserID,
      deleted_at: nil
    )
    @message_string.update!(deleted_at: nil)
  end

  test "admin reaches a read-only case overview from the active mediations board" do
    sign_in_as(@admin)
    visit admin_mediations_path

    assert_selector "h2", text: "Active Mediations"

    # Multiple cases may be active, so target this mediation's row explicitly
    click_link "View Case", href: mediator_case_path(@mediation)

    assert_current_path mediator_case_path(@mediation)
    assert_selector "h1", text: "Mediation Case Details"
    assert_link "Back to Mediations"
    assert_link "Open Chat"
    # Read-only: mediator-only terminate action is not offered to admins
    assert_no_button "Terminate Mediation"
  end

  test "admin views the chat pane in read-only mode" do
    sign_in_as(@admin)
    visit message_path(@mediation.ConversationID)

    # Visible read-only state of the composer
    assert_text "You are viewing this conversation in read-only mode."
    # No composer or conversation actions for read-only admins
    assert_no_button "Send"
    assert_no_button "End Mediation"
    assert_no_button "End Negotiation"
    assert_no_button "Request a mediator"
    # Admins get the same case-overview shortcut mediators have
    assert_link "Case overview"

    # The admin banner lives in the (collapsed) conversation details panel
    click_button "Conversation details"
    assert_text "Administrator View"
  end

  test "admin can jump from the chat back to the case overview" do
    sign_in_as(@admin)
    visit message_path(@mediation.ConversationID)

    click_link "Case overview"

    assert_current_path mediator_case_path(@mediation)
    assert_selector "h1", text: "Mediation Case Details"
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
