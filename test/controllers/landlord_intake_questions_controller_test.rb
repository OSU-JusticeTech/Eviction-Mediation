require "test_helper"

class LandlordIntakeQuestionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @landlord = users(:landlord1)
    @tenant = users(:tenant1)
    @conversation = primary_message_groups(:one)
  end

  VALID_INTAKE_PARAMS = {
    Reason: [ "Failure to Pay Rent" ],
    LandlordDescribeCause: "Tenant has not paid for two months",
    DesiredOutcome: "Receive Payment",
    AmountClaimed: 2000,
    MonthlyRent: 1000,
    DateDue: Date.today.to_s,
    AcceptPaymentPlan: "false"
  }.freeze

  test "redirects to login when not authenticated" do
    get new_landlord_intake_question_path
    assert_redirected_to login_path
  end

  test "redirects non-landlord users" do
    log_in_as(@tenant)
    get new_landlord_intake_question_path
    assert_redirected_to messages_path
  end

  test "renders new intake form for logged-in landlord" do
    log_in_as(@landlord)
    get new_landlord_intake_question_path
    assert_response :success
  end

  test "shows Unknown reason when the tenant requested the negotiation" do
    @conversation.update!(requested_by: "Tenant")
    log_in_as(@landlord)

    get new_landlord_intake_question_path(conversation_id: @conversation.ConversationID)
    assert_response :success
    assert_select "#reason_unknown"
  end

  test "hides Unknown reason when the landlord requested the negotiation" do
    @conversation.update!(requested_by: "Landlord")
    log_in_as(@landlord)

    get new_landlord_intake_question_path(conversation_id: @conversation.ConversationID)
    assert_response :success
    assert_select "#reason_unknown", count: 0
  end

  test "creates intake question with valid params" do
    log_in_as(@landlord)

    assert_difference("LandlordIntakeQuestion.count", 1) do
      post landlord_intake_questions_path, params: {
        landlord_intake_question: {
          Reason: [ "Failure to Pay Rent" ],
          LandlordDescribeCause: "Tenant has not paid for two months",
          DesiredOutcome: "Receive Payment",
          AmountClaimed: 2000,
          MonthlyRent: 1000,
          DateDue: Date.today.to_s,
          AcceptPaymentPlan: "false"
        }
      }
    end

    assert_redirected_to messages_path
    intake = LandlordIntakeQuestion.order(:LandlordIntakeID).last
    assert_equal [ "Failure to Pay Rent" ], intake.reasons
    assert_equal "Receive Payment", intake.DesiredOutcome
  end

  test "creates intake with Unknown reason without requiring other fields" do
    log_in_as(@landlord)

    assert_difference("LandlordIntakeQuestion.count", 1) do
      post landlord_intake_questions_path, params: {
        landlord_intake_question: {
          Reason: [ "Unknown" ]
        }
      }
    end

    assert_redirected_to messages_path
    intake = LandlordIntakeQuestion.order(:LandlordIntakeID).last
    assert_equal [ "Unknown" ], intake.reasons
  end

  test "links saved intake to the landlord's mediation" do
    log_in_as(@landlord)

    post landlord_intake_questions_path, params: {
      landlord_intake_question: {
        Reason: [ "Failure to Pay Rent" ],
        DesiredOutcome: "Have Tenant Vacate",
        AmountClaimed: 500,
        AcceptPaymentPlan: "false"
      }
    }

    assert_redirected_to messages_path
    intake = LandlordIntakeQuestion.order(:LandlordIntakeID).last
    assert_equal intake.LandlordIntakeID, @conversation.reload.LandlordIntakeID
  end

  test "rejects intake with no reason selected" do
    log_in_as(@landlord)

    assert_no_difference("LandlordIntakeQuestion.count") do
      post landlord_intake_questions_path, params: {
        landlord_intake_question: {
          Reason: [],
          DesiredOutcome: "Receive Payment",
          AmountClaimed: 500,
          AcceptPaymentPlan: "false"
        }
      }
    end
  end

  test "visiting intake without a pending request or existing mediation redirects" do
    @conversation.update!(deleted_at: Time.current)
    log_in_as(@landlord)

    get new_landlord_intake_question_path
    assert_redirected_to messages_path
    assert_equal "We couldn't find a negotiation awaiting your intake.", flash[:alert]
  end

  test "submitting intake without a matching mediation does not silently succeed" do
    @conversation.update!(deleted_at: Time.current)
    log_in_as(@landlord)

    assert_no_difference("LandlordIntakeQuestion.count") do
      post landlord_intake_questions_path, params: { landlord_intake_question: VALID_INTAKE_PARAMS }
    end

    assert_redirected_to messages_path
    assert_equal "We couldn't find a negotiation awaiting your intake.", flash[:alert]
  end

  # --- Pre-request intake (requester completes intake before the request exists) ---

  test "completing intake before a request creates the mediation with intake attached" do
    tenant2 = users(:tenant2)
    log_in_as(@landlord)

    post mediations_path, params: { tenant_email: tenant2.Email }
    assert_redirected_to new_landlord_intake_question_path

    get new_landlord_intake_question_path
    assert_response :success
    assert_select "#reason_unknown", count: 0

    assert_difference [ "LandlordIntakeQuestion.count", "PrimaryMessageGroup.count" ], 1 do
      post landlord_intake_questions_path, params: { landlord_intake_question: VALID_INTAKE_PARAMS }
    end

    mediation = PrimaryMessageGroup.order(:ConversationID).last
    intake = LandlordIntakeQuestion.order(:LandlordIntakeID).last

    assert_equal intake.LandlordIntakeID, mediation.LandlordIntakeID
    assert_equal tenant2.UserID, mediation.TenantID
    assert_equal @landlord.UserID, mediation.LandlordID
    assert_equal "Landlord", mediation.requested_by
    assert_redirected_to messages_path
    assert_equal "Negotiation request sent to #{tenant2.Email}. If they have an account, they can accept your request. Otherwise, they'll be invited to join the site.", flash[:notice]
    assert_nil session[:pending_mediation_request]
  end

  test "sends the tenant a notification email when completing pre-request intake and their preference is on" do
    tenant2 = users(:tenant2)
    tenant2.update!(notify_new_mediation_request: true)
    log_in_as(@landlord)

    post mediations_path, params: { tenant_email: tenant2.Email }

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      post landlord_intake_questions_path, params: { landlord_intake_question: VALID_INTAKE_PARAMS }
    end

    tenant_emails = ActionMailer::Base.deliveries.select { |m| m.to.include?(tenant2.Email) }
    assert_not_empty tenant_emails
  end

  test "does not email the tenant when completing pre-request intake and their preference is off" do
    tenant2 = users(:tenant2)
    tenant2.update!(notify_new_mediation_request: false)
    log_in_as(@landlord)

    post mediations_path, params: { tenant_email: tenant2.Email }

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      post landlord_intake_questions_path, params: { landlord_intake_question: VALID_INTAKE_PARAMS }
    end

    tenant_emails = ActionMailer::Base.deliveries.select { |m| m.to.include?(tenant2.Email) }
    assert_empty tenant_emails
  end

  test "rejects Unknown-only reason when completing intake before a request" do
    tenant2 = users(:tenant2)
    log_in_as(@landlord)

    post mediations_path, params: { tenant_email: tenant2.Email }

    assert_no_difference [ "LandlordIntakeQuestion.count", "PrimaryMessageGroup.count" ] do
      post landlord_intake_questions_path, params: { landlord_intake_question: { Reason: [ "Unknown" ] } }
    end

    assert_response :unprocessable_entity
    assert_not_nil session[:pending_mediation_request]
  end

  test "target becoming ineligible between the email step and intake submission rolls back cleanly" do
    tenant2 = users(:tenant2)
    log_in_as(@landlord)

    post mediations_path, params: { tenant_email: tenant2.Email }
    tenant2.update!(Email: "changed_tenant@email.com")

    assert_no_difference [ "LandlordIntakeQuestion.count", "PrimaryMessageGroup.count" ] do
      post landlord_intake_questions_path, params: { landlord_intake_question: VALID_INTAKE_PARAMS }
    end

    assert_redirected_to new_mediation_path
    assert_equal "No tenant account found with that email.", flash[:alert]
    assert_nil session[:pending_mediation_request]
  end
end
