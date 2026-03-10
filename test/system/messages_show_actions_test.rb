require "application_system_test_case"

class MessagesShowActionsTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediation = primary_message_groups(:one)
    @message_string = message_strings(:one)
    SurveyResponse.where(conversation_id: @mediation.ConversationID).delete_all
  end

  test "tenant can request a mediator from message actions" do
    @mediation.update!(MediatorRequested: false, MediatorAssigned: false, deleted_at: nil)
    @message_string.update!(deleted_at: nil)

    sign_in_as(@tenant)
    visit message_path(@mediation.ConversationID)
    dismiss_chat_disclaimer_if_present

    click_button "Request a mediator"
    click_button "Confirm request"

    assert_current_path message_path(@mediation.ConversationID)
    assert_text "Mediator requested. An admin will assign one shortly."
    assert @mediation.reload.MediatorRequested
  end

  test "landlord can end negotiation from message actions" do
    @mediation.update!(MediatorRequested: false, MediatorAssigned: false, deleted_at: nil)
    @message_string.update!(deleted_at: nil)

    sign_in_as(@landlord)
    visit message_path(@mediation.ConversationID)
    dismiss_chat_disclaimer_if_present

    click_button "End Negotiation"
    click_button "Confirm end"

    assert_current_path mediation_survey_path(@mediation.ConversationID)
    assert_not_nil @mediation.reload.deleted_at
    assert_not_nil @message_string.reload.deleted_at
  end

  test "ended mediation redirects to ended prompt when opening conversation" do
    @mediation.update!(deleted_at: Time.current)
    @message_string.update!(deleted_at: Time.current)

    sign_in_as(@tenant)
    visit message_path(@mediation.ConversationID)

    assert_current_path mediation_ended_prompt_path(@mediation.ConversationID)
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

  def dismiss_chat_disclaimer_if_present
    return unless page.has_button?("I Understand", wait: 1)

    click_button "I Understand"
  end
end