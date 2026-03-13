require "test_helper"

class MediatorMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = users(:tenant1)
    @side_conversation = side_message_groups(:two)
  end

  test "redirects to login when not authenticated" do
    post mediator_messages_path, params: {
      conversation_id: @side_conversation.ConversationID,
      recipient_id: @side_conversation.MediatorID,
      Contents: "Hello mediator"
    }

    assert_redirected_to login_path
  end

  test "creates a mediator message for authorized user" do
    log_in_as(@tenant)

    assert_difference("Message.count", 1) do
      post mediator_messages_path,
        params: {
          conversation_id: @side_conversation.ConversationID,
          recipient_id: @side_conversation.MediatorID,
          Contents: "Simple test message for mediator"
        },
        as: :json
    end

    assert_response :success
  end
end
