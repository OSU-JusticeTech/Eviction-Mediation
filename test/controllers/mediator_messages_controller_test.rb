require "test_helper"

class MediatorMessagesControllerTest < ActionDispatch::IntegrationTest
  FakeErrorContainer = Struct.new(:messages) do
    def full_messages
      messages
    end
  end

  FakeMessage = Struct.new(:save_result, :errors) do
    def save
      save_result
    end
  end

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

  test "returns accepted for duplicate message" do
    log_in_as(@tenant)

    Message.create!(
      ConversationID: @side_conversation.ConversationID,
      SenderID: @tenant.UserID,
      recipientID: @side_conversation.MediatorID,
      MessageDate: Time.current,
      Contents: "dupe-side"
    )

    post mediator_messages_path,
      params: {
        conversation_id: @side_conversation.ConversationID,
        recipient_id: @side_conversation.MediatorID,
        Contents: "dupe-side"
      },
      as: :json

    assert_response :accepted
  end

  test "returns not found for recipient mismatch" do
    log_in_as(@tenant)

    post mediator_messages_path,
      params: {
        conversation_id: @side_conversation.ConversationID,
        recipient_id: users(:admin1).UserID,
        Contents: "invalid"
      },
      as: :json

    assert_response :not_found
  end

  test "mediator can send message to side conversation user" do
    mediator = users(:mediator2)
    log_in_as(mediator)

    assert_difference("Message.count", 1) do
      post mediator_messages_path,
        params: {
          conversation_id: @side_conversation.ConversationID,
          recipient_id: @side_conversation.UserID,
          Contents: "Mediator reply"
        },
        as: :json
    end

    assert_response :success
  end

  test "non participant gets not found" do
    outsider = users(:landlord1)
    log_in_as(outsider)

    post mediator_messages_path,
      params: {
        conversation_id: @side_conversation.ConversationID,
        recipient_id: @side_conversation.MediatorID,
        Contents: "Should fail"
      },
      as: :json

    assert_response :not_found
  end

  test "missing conversation id returns not found" do
    log_in_as(@tenant)

    post mediator_messages_path,
      params: {
        recipient_id: @side_conversation.MediatorID,
        Contents: "Missing convo"
      },
      as: :json

    assert_response :not_found
  end

  test "unassigned mediator gets not found" do
    log_in_as(users(:mediator1))

    post mediator_messages_path,
      params: {
        conversation_id: @side_conversation.ConversationID,
        recipient_id: @side_conversation.UserID,
        Contents: "Wrong mediator"
      },
      as: :json

    assert_response :not_found
  end

  test "html request succeeds and returns ok" do
    log_in_as(@tenant)

    post mediator_messages_path,
      params: {
        conversation_id: @side_conversation.ConversationID,
        recipient_id: @side_conversation.MediatorID,
        Contents: "HTML request"
      }

    assert_response :success
  end

  test "create with file attachment persists attachment" do
    log_in_as(@tenant)

    assert_difference("FileAttachment.count", 1) do
      post mediator_messages_path,
        params: {
          conversation_id: @side_conversation.ConversationID,
          recipient_id: @side_conversation.MediatorID,
          Contents: "Attached",
          file_id: file_drafts(:one).FileID
        },
        as: :json
    end

    assert_response :success
  end

  test "create with missing file draft still succeeds without attachment" do
    log_in_as(@tenant)

    assert_no_difference("FileAttachment.count") do
      post mediator_messages_path,
        params: {
          conversation_id: @side_conversation.ConversationID,
          recipient_id: @side_conversation.MediatorID,
          Contents: "Missing file",
          file_id: "does-not-exist"
        },
        as: :json
    end

    assert_response :success
  end

  test "returns unprocessable entity json when message save fails" do
    log_in_as(@tenant)
    fake = FakeMessage.new(false, FakeErrorContainer.new([ "forced failure" ]))

    with_stubbed_message_new(fake) do
      post mediator_messages_path,
        params: {
          conversation_id: @side_conversation.ConversationID,
          recipient_id: @side_conversation.MediatorID,
          Contents: "Fails"
        },
        as: :json
    end

    assert_response :unprocessable_entity
  end

  test "returns unprocessable entity html when message save fails" do
    log_in_as(@tenant)
    fake = FakeMessage.new(false, FakeErrorContainer.new([ "forced failure" ]))

    with_stubbed_message_new(fake) do
      post mediator_messages_path,
        params: {
          conversation_id: @side_conversation.ConversationID,
          recipient_id: @side_conversation.MediatorID,
          Contents: "Fails html"
        }
    end

    assert_response :unprocessable_entity
  end

  private

  def with_stubbed_message_new(fake_message)
    original_new = Message.method(:new)
    Message.define_singleton_method(:new) { |_attrs| fake_message }
    yield
  ensure
    Message.define_singleton_method(:new, original_new)
  end
end
