require "test_helper"

class LandlordIntakeQuestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @landlord = users(:landlord1)
    @tenant = users(:tenant1)
    @conversation = primary_message_groups(:one)
  end

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
end
