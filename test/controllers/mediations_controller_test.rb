require "test_helper"

class MediationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediation = primary_message_groups(:one)
  end

  def log_in_as(user, expect_success: true)
    post login_path, params: { email: user[:Email], password: "password" }
    assert_redirected_to dashboard_url
    follow_redirect!
    assert_response(:success) if expect_success
  end

  test "tenant requesting an existing landlord is sent to intake before the request is created" do
    log_in_as(@tenant)
    assert_no_difference("PrimaryMessageGroup.count") do
      post mediations_path, params: { landlord_email: @landlord[:Email] }
    end

    assert_redirected_to new_intake_question_path
    assert_equal @landlord[:Email], session[:pending_mediation_request]["target_email"]
  end

  test "landlord requesting an existing tenant is sent to intake before the request is created" do
    log_in_as(@landlord)
    assert_no_difference("PrimaryMessageGroup.count") do
      post mediations_path, params: { tenant_email: @tenant[:Email] }
    end

    assert_redirected_to new_landlord_intake_question_path
    assert_equal @tenant[:Email], session[:pending_mediation_request]["target_email"]
  end

  test "landlord requesting an unregistered tenant email sends an invitation" do
    log_in_as(@landlord)
    ActionMailer::Base.deliveries.clear

    assert_no_difference("PrimaryMessageGroup.count") do
      post mediations_path, params: { tenant_email: "not_registered@example.com" }
    end

    assert_redirected_to messages_path
    assert_match(/Invitation email sent/, flash[:notice])
    tenant_emails = ActionMailer::Base.deliveries.select { |m| m.to.include?("not_registered@example.com") }
    assert_not_empty tenant_emails
  end

  test "landlord requesting a tenant email that belongs to a non-tenant account is blocked" do
    mediator = users(:mediator1)
    log_in_as(@landlord)
    ActionMailer::Base.deliveries.clear

    assert_no_difference("PrimaryMessageGroup.count") do
      post mediations_path, params: { tenant_email: mediator.Email }
    end

    assert_redirected_to new_mediation_path
    assert_equal "No tenant account found with that email.", flash[:alert]
    assert_empty ActionMailer::Base.deliveries.select { |m| m.to.include?(mediator.Email) }
  end

  test "tenant requesting a landlord email that belongs to a non-landlord account is blocked" do
    admin = users(:admin1)
    log_in_as(@tenant)
    ActionMailer::Base.deliveries.clear

    assert_no_difference("PrimaryMessageGroup.count") do
      post mediations_path, params: { landlord_email: admin.Email }
    end

    assert_redirected_to new_mediation_path
    assert_equal "No landlord account found with that email.", flash[:alert]
    assert_empty ActionMailer::Base.deliveries.select { |m| m.to.include?(admin.Email) }
  end

  test "non-tenant/non-landlord cannot create mediation" do
    mediator = users(:mediator1)
    log_in_as(mediator)
    assert_no_difference("PrimaryMessageGroup.count") do
      post mediations_path, params: { tenant_email: @tenant[:Email] }
    end

    assert_redirected_to root_path
    assert_equal "You are not authorized to access this page.", flash[:alert]
  end

  test "landlord can accept mediation" do
    log_in_as(@landlord)

    post accept_mediation_path(@mediation)
    assert @mediation.reload.accepted_by_landlord
    assert_redirected_to mediations_path
    assert_equal "Negotiation accepted. You can now view and respond to the negotiation.", flash[:notice]
  end

  test "unauthorized landlord cannot accept mediation" do
    another_landlord = users(:landlord2)
    log_in_as(another_landlord)

    post accept_mediation_path(@mediation)
    assert_redirected_to mediations_path
    assert_equal "You are not authorized to accept this negotiation.", flash[:alert]
    assert_not @mediation.reload.accepted_by_landlord
  end

  test "require login to access mediations" do
    get new_mediation_url
    assert_redirected_to login_path
    assert_equal "You must be logged in to access the mediations.", flash[:alert]
  end

  test "require login to accept mediation" do
    post accept_mediation_path(@mediation)

    assert_redirected_to login_path
    assert_equal "You must be logged in to access the mediations.", flash[:alert]
    assert_not @mediation.reload.accepted_by_landlord
  end

  test "landlord can reject mediation" do
    log_in_as(@landlord)

    post reject_mediation_path(@mediation)

    assert_redirected_to messages_path
    assert_not_nil @mediation.reload.deleted_at
    assert_not_nil @mediation.linked_message_string.reload.deleted_at
  end

  test "outsider cannot reject mediation" do
    outsider = users(:tenant2)
    log_in_as(outsider)

    post reject_mediation_path(@mediation)

    assert_redirected_to messages_path
    assert_equal "You are not authorized to reject this negotiation.", flash[:alert]
  end

  test "new mediation denies unsupported role" do
    admin = users(:admin1)
    log_in_as(admin)

    get new_mediation_path

    assert_redirected_to mediations_path
    assert_equal "You are not authorized to start a negotiation.", flash[:alert]
  end

  test "mediator end conversation redirects to third party list" do
    mediator = users(:mediator1)
    log_in_as(mediator)

    patch end_mediation_path(@mediation)

    assert_redirected_to third_party_mediations_path
    assert_equal "Mediation terminated.", flash[:notice]
  end

  test "tenant good faith update writes landlord feedback field" do
    @mediation.update!(deleted_at: Time.current)
    log_in_as(@tenant)

    patch good_faith_response_path(@mediation.ConversationID), params: { role: "Tenant", good_faith: "true" }

    assert_redirected_to mediation_survey_path(@mediation.ConversationID)
    assert_equal true, @mediation.reload.EndOfConversationGoodFaithLandlord
  end

  test "good faith form redirects for active mediation" do
    @mediation.update!(deleted_at: nil)
    log_in_as(@tenant)

    get good_faith_response_path(@mediation.ConversationID)

    assert_redirected_to messages_path
    assert_equal "Mediation not found or still ongoing.", flash[:alert]
  end

  test "survey form redirects when survey already submitted" do
    @mediation.update!(deleted_at: Time.current)
    log_in_as(@tenant)

    get mediation_survey_path(@mediation.ConversationID)

    assert_redirected_to messages_path
    assert_equal "You have already submitted a survey for this mediation.", flash[:notice]
  end

  test "submit survey denies unauthorized role" do
    @mediation.update!(deleted_at: Time.current)
    mediator = users(:mediator1)
    log_in_as(mediator)

    post mediation_survey_path(@mediation.ConversationID), params: {
      survey_response: {
        tool_ease: "easy",
        info_clear: "yes",
        understood_mediation: "yes",
        other_participated: "yes",
        good_faith: "yes",
        helped_communicate: "yes",
        would_recommend: "yes",
        liked_most: "Flow",
        should_improve: "None",
        device_used: "computer"
      }
    }

    assert_redirected_to messages_path
    assert_equal "You are not authorized to submit this survey.", flash[:alert]
  end

  # Notification-preference enforcement now happens once the request is
  # actually created (after intake), so that coverage lives in
  # test/controllers/intake_questions_controller_test.rb and
  # test/controllers/landlord_intake_questions_controller_test.rb.

  # --- Outcome -----------------------------------------------------

  test "requester can set the outcome on an ended negotiation with no mediator" do
    @mediation.update!(deleted_at: Time.current, MediatorAssigned: false,
                       MediatorID: nil, requested_by: "Tenant")
    log_in_as(@tenant)

    patch mediation_outcome_path(@mediation.ConversationID),
          params: { outcome: "Closed with agreement" }

    assert_equal "Closed with agreement", @mediation.reload.Outcome
  end

  test "non-requester cannot set the outcome when no mediator is assigned" do
    @mediation.update!(deleted_at: Time.current, MediatorAssigned: false,
                       MediatorID: nil, requested_by: "Tenant")
    log_in_as(@landlord)

    patch mediation_outcome_path(@mediation.ConversationID),
          params: { outcome: "Closed with agreement" }

    assert_nil @mediation.reload.Outcome
    assert_match(/not authorized/i, flash[:alert])
  end

  test "assigned mediator can set the outcome" do
    mediator = users(:mediator1)
    @mediation.update!(deleted_at: Time.current, MediatorAssigned: true,
                       MediatorID: mediator.UserID, requested_by: "Tenant")
    log_in_as(mediator)

    patch mediation_outcome_path(@mediation.ConversationID),
          params: { outcome: "Closed without agreement" }

    assert_equal "Closed without agreement", @mediation.reload.Outcome
  end

  test "requester cannot set the outcome once a mediator is assigned" do
    mediator = users(:mediator1)
    @mediation.update!(deleted_at: Time.current, MediatorAssigned: true,
                       MediatorID: mediator.UserID, requested_by: "Tenant")
    log_in_as(@tenant)

    patch mediation_outcome_path(@mediation.ConversationID),
          params: { outcome: "Closed with agreement" }

    assert_nil @mediation.reload.Outcome
    assert_match(/not authorized/i, flash[:alert])
  end

  test "invalid outcome values are rejected" do
    @mediation.update!(deleted_at: Time.current, MediatorAssigned: false,
                       MediatorID: nil, requested_by: "Tenant")
    log_in_as(@tenant)

    patch mediation_outcome_path(@mediation.ConversationID),
          params: { outcome: "Bogus outcome" }

    assert_nil @mediation.reload.Outcome
    assert_match(/valid outcome/i, flash[:alert])
  end

  test "outcome cannot be set on an active mediation" do
    @mediation.update!(deleted_at: nil, requested_by: "Tenant")
    log_in_as(@tenant)

    patch mediation_outcome_path(@mediation.ConversationID),
          params: { outcome: "Closed with agreement" }

    assert_nil @mediation.reload.Outcome
    assert_match(/still ongoing/i, flash[:alert])
  end
end
