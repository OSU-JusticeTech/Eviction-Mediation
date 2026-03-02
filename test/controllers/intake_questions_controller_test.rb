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

  test "creates intake question with valid params" do
    log_in_as(@tenant)

    assert_difference("IntakeQuestion.count", 1) do
      post intake_questions_path, params: {
        conversation_id: @conversation.ConversationID,
        intake_question: {
          Reason: "Failure to Pay Rent",
          DescribeCause: "Lost job hours",
          BestOption: "Pay Missed Rent",
          Section8: "false",
          MoneyOwed: 1000,
          TotalCostOrMonthly: "true",
          MonthlyRent: 900,
          DateDue: Date.today.to_s,
          PayableToday: 300
        }
      }
    end

    assert_redirected_to messages_path
  end
end
