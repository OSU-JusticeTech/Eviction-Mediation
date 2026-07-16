require "test_helper"

class IntakeQuestionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @tenant = users(:tenant1)
    @conversation = primary_message_groups(:one)
  end

  VALID_INTAKE_PARAMS = {
    Reason: [ "Failure to Pay Rent" ],
    DescribeCause: "Lost job hours",
    BestOption: "Pay Missed Rent",
    Section8: "false",
    MoneyOwed: 1000,
    TotalCostOrMonthly: "false",
    MonthlyRent: 900,
    DateDue: Date.today.to_s,
    PayableToday: 300
  }.freeze

  test "redirects to login when not authenticated" do
    get new_intake_question_path(conversation_id: @conversation.ConversationID)
    assert_redirected_to login_path
  end

  test "renders new intake form for logged in tenant" do
    log_in_as(@tenant)

    get new_intake_question_path(conversation_id: @conversation.ConversationID)
    assert_response :success
  end

  test "shows Unknown reason when the landlord requested the negotiation" do
    @conversation.update!(requested_by: "Landlord")
    log_in_as(@tenant)

    get new_intake_question_path(conversation_id: @conversation.ConversationID)
    assert_response :success
    assert_select "#reason_unknown"
  end

  test "hides Unknown reason when the tenant requested the negotiation" do
    @conversation.update!(requested_by: "Tenant")
    log_in_as(@tenant)

    get new_intake_question_path(conversation_id: @conversation.ConversationID)
    assert_response :success
    assert_select "#reason_unknown", count: 0
  end

  test "creates intake question with valid params" do
    log_in_as(@tenant)

    assert_difference("IntakeQuestion.count", 1) do
      post intake_questions_path, params: {
        conversation_id: @conversation.ConversationID,
        intake_question: {
          Reason: [ "Failure to Pay Rent" ],
          DescribeCause: "Lost job hours",
          BestOption: "Pay Missed Rent",
          Section8: "false",
          MoneyOwed: 1000,
          TotalCostOrMonthly: "false",
          MonthlyRent: 900,
          DateDue: Date.today.to_s,
          PayableToday: 300
        }
      }
    end

    assert_redirected_to messages_path
  end

  test "creates intake question with multiple reasons" do
    log_in_as(@tenant)

    assert_difference("IntakeQuestion.count", 1) do
      post intake_questions_path, params: {
        conversation_id: @conversation.ConversationID,
        intake_question: {
          Reason: [ "Failure to Pay Rent", "Damage to Property", "Unsafe" ],
          DescribeCause: "Multiple issues",
          BestOption: "Pay Missed Rent",
          Section8: "false",
          MoneyOwed: 1000,
          TotalCostOrMonthly: "false",
          MonthlyRent: 900,
          DateDue: Date.today.to_s,
          PayableToday: 300
        }
      }
    end

    assert_redirected_to messages_path
    intake = IntakeQuestion.order(:IntakeID).last
    assert_equal [ "Failure to Pay Rent", "Damage to Property", "Unsafe" ], intake.reasons
  end

  test "rejects intake question with no reason selected" do
    log_in_as(@tenant)

    assert_no_difference("IntakeQuestion.count") do
      post intake_questions_path, params: {
        conversation_id: @conversation.ConversationID,
        intake_question: {
          Reason: [],
          DescribeCause: "No reason given",
          BestOption: "Pay Missed Rent",
          Section8: "false",
          MoneyOwed: 1000,
          TotalCostOrMonthly: "false",
          MonthlyRent: 900,
          DateDue: Date.today.to_s,
          PayableToday: 300
        }
      }
    end
  end

  test "creates intake with Unknown reason without requiring other fields" do
    log_in_as(@tenant)

    assert_difference("IntakeQuestion.count", 1) do
      post intake_questions_path, params: {
        conversation_id: @conversation.ConversationID,
        intake_question: {
          Reason: [ "Unknown" ]
        }
      }
    end

    assert_redirected_to messages_path
    intake = IntakeQuestion.order(:IntakeID).last
    assert_equal [ "Unknown" ], intake.reasons
  end

  test "visiting intake without a pending request or existing mediation redirects" do
    @conversation.update!(deleted_at: Time.current)
    log_in_as(@tenant)

    get new_intake_question_path
    assert_redirected_to messages_path
    assert_equal "We couldn't find a negotiation awaiting your intake.", flash[:alert]
  end

  test "submitting intake without a matching mediation does not silently succeed" do
    @conversation.update!(deleted_at: Time.current)
    log_in_as(@tenant)

    assert_no_difference("IntakeQuestion.count") do
      post intake_questions_path, params: { intake_question: VALID_INTAKE_PARAMS }
    end

    assert_redirected_to messages_path
    assert_equal "We couldn't find a negotiation awaiting your intake.", flash[:alert]
  end

  # --- Pre-request intake (requester completes intake before the request exists) ---

  test "completing intake before a request creates the mediation with intake attached" do
    landlord2 = users(:landlord2)
    log_in_as(@tenant)

    post mediations_path, params: { landlord_email: landlord2.Email }
    assert_redirected_to new_intake_question_path

    get new_intake_question_path
    assert_response :success
    assert_select "#reason_unknown", count: 0

    assert_difference [ "IntakeQuestion.count", "PrimaryMessageGroup.count" ], 1 do
      post intake_questions_path, params: { intake_question: VALID_INTAKE_PARAMS }
    end

    mediation = PrimaryMessageGroup.order(:ConversationID).last
    intake = IntakeQuestion.order(:IntakeID).last

    assert_equal intake.IntakeID, mediation.IntakeID
    assert_equal landlord2.UserID, mediation.LandlordID
    assert_equal @tenant.UserID, mediation.TenantID
    assert_equal "Tenant", mediation.requested_by
    assert_redirected_to messages_path
    assert_equal "Negotiation requested with #{landlord2.CompanyName || landlord2.Email}.", flash[:notice]
    assert_nil session[:pending_mediation_request]
  end

  test "sends the landlord a notification email when completing pre-request intake and their preference is on" do
    landlord2 = users(:landlord2)
    landlord2.update!(notify_new_mediation_request: true)
    log_in_as(@tenant)

    post mediations_path, params: { landlord_email: landlord2.Email }

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      post intake_questions_path, params: { intake_question: VALID_INTAKE_PARAMS }
    end

    landlord_emails = ActionMailer::Base.deliveries.select { |m| m.to.include?(landlord2.Email) }
    assert_not_empty landlord_emails
  end

  test "does not email the landlord when completing pre-request intake and their preference is off" do
    landlord2 = users(:landlord2)
    landlord2.update!(notify_new_mediation_request: false)
    log_in_as(@tenant)

    post mediations_path, params: { landlord_email: landlord2.Email }

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      post intake_questions_path, params: { intake_question: VALID_INTAKE_PARAMS }
    end

    landlord_emails = ActionMailer::Base.deliveries.select { |m| m.to.include?(landlord2.Email) }
    assert_empty landlord_emails
  end

  test "rejects Unknown-only reason when completing intake before a request" do
    landlord2 = users(:landlord2)
    log_in_as(@tenant)

    post mediations_path, params: { landlord_email: landlord2.Email }

    assert_no_difference [ "IntakeQuestion.count", "PrimaryMessageGroup.count" ] do
      post intake_questions_path, params: { intake_question: { Reason: [ "Unknown" ] } }
    end

    assert_response :unprocessable_entity
    assert_not_nil session[:pending_mediation_request]
  end

  test "target becoming ineligible between the email step and intake submission rolls back cleanly" do
    landlord2 = users(:landlord2)
    log_in_as(@tenant)

    post mediations_path, params: { landlord_email: landlord2.Email }
    landlord2.update!(Email: "changed_address@email.com")

    assert_no_difference [ "IntakeQuestion.count", "PrimaryMessageGroup.count" ] do
      post intake_questions_path, params: { intake_question: VALID_INTAKE_PARAMS }
    end

    assert_redirected_to new_mediation_path
    assert_equal "No landlord account found with that email.", flash[:alert]
    assert_nil session[:pending_mediation_request]
  end
end
