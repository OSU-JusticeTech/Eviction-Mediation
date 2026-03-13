require "application_system_test_case"

class MediationsSurveyTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediation = primary_message_groups(:one)
    @message_string = message_strings(:one)
    SurveyResponse.where(conversation_id: @mediation.ConversationID).delete_all
  end

  test "active mediation cannot access survey form" do
    @mediation.update!(deleted_at: nil)
    @message_string.update!(deleted_at: nil)

    sign_in_as(@tenant)
    visit mediation_survey_path(@mediation.ConversationID)

    assert_current_path messages_path
    assert_text "Mediation not found or still ongoing."
  end

  test "tenant can submit survey for ended mediation" do
    @mediation.update!(deleted_at: Time.current)
    @message_string.update!(deleted_at: Time.current)

    sign_in_as(@tenant)
    visit mediation_survey_path(@mediation.ConversationID)

    assert_selector "h1", text: "End of Mediation Survey"

    choose "ease_easy"
    choose "info_yes"
    choose "understood_yes"
    choose "participated_yes"
    choose "good_faith_somewhat"
    choose "communicate_yes"
    choose "recommend_yes"
    choose "device_computer"
    fill_in "survey_response_liked_most", with: "Easy to use"
    fill_in "survey_response_should_improve", with: "Better response times"
    click_button "Submit Survey"

    assert_current_path messages_path
    assert_text "Thank you for completing the survey!"
    assert_equal 1, SurveyResponse.where(conversation_id: @mediation.ConversationID, user_id: @tenant.UserID).count
  end

  test "landlord can submit survey for ended mediation" do
    @mediation.update!(deleted_at: Time.current)
    @message_string.update!(deleted_at: Time.current)

    sign_in_as(@landlord)
    visit mediation_survey_path(@mediation.ConversationID)

    assert_selector "h1", text: "End of Mediation Survey"

    choose "ease_neutral"
    choose "info_somewhat"
    choose "understood_yes"
    choose "participated_yes"
    choose "good_faith_yes"
    choose "communicate_somewhat"
    choose "recommend_maybe"
    choose "device_phone"
    fill_in "survey_response_liked_most", with: "Clear process"
    fill_in "survey_response_should_improve", with: "Faster notifications"
    click_button "Submit Survey"

    assert_current_path messages_path
    assert_text "Thank you for completing the survey!"
    assert_equal 1, SurveyResponse.where(conversation_id: @mediation.ConversationID, user_id: @landlord.UserID).count
  end

  test "duplicate tenant survey submission is blocked" do
    @mediation.update!(deleted_at: Time.current)
    @message_string.update!(deleted_at: Time.current)
    SurveyResponse.create!(
      conversation_id: @mediation.ConversationID,
      user_id: @tenant.UserID,
      user_role: "Tenant",
      tool_ease: "easy",
      info_clear: "yes",
      understood_mediation: "yes",
      other_participated: "yes",
      good_faith: "yes",
      helped_communicate: "yes",
      would_recommend: "yes",
      device_used: "computer"
    )

    sign_in_as(@tenant)
    visit mediation_survey_path(@mediation.ConversationID)

    assert_current_path messages_path
    assert_text "You have already submitted a survey for this mediation."
  end

  test "duplicate landlord survey submission is blocked" do
    @mediation.update!(deleted_at: Time.current)
    @message_string.update!(deleted_at: Time.current)
    SurveyResponse.create!(
      conversation_id: @mediation.ConversationID,
      user_id: @landlord.UserID,
      user_role: "Landlord",
      tool_ease: "easy",
      info_clear: "yes",
      understood_mediation: "yes",
      other_participated: "yes",
      good_faith: "yes",
      helped_communicate: "yes",
      would_recommend: "yes",
      device_used: "computer"
    )

    sign_in_as(@landlord)
    visit mediation_survey_path(@mediation.ConversationID)

    assert_current_path messages_path
    assert_text "You have already submitted a survey for this mediation."
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