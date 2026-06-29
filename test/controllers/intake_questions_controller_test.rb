require "test_helper"

class IntakeQuestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = users(:tenant1)
    @conversation = primary_message_groups(:one)
  end

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
end
