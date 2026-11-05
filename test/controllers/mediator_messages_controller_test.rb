require "test_helper"

class MediatorMessagesControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

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
    @mediation = primary_message_groups(:one)
    @mediation.update!(MediatorID: users(:mediator2).UserID, MediatorAssigned: true, deleted_at: nil)
    string = MessageString.create!(Role: "Side")
    @side_conversation = SideMessageGroup.create!(ConversationID: string.ConversationID,
      UserID: @tenant.UserID, MediatorID: users(:mediator2).UserID)
    @mediation.update!(TenantSideConversationID: string.ConversationID)
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

  test "retired and closed conversations cannot create messages or broadcasts" do
    log_in_as(@tenant)
    @mediation.update!(TenantSideConversationID: nil)
    assert_private_post_rejected
    @mediation.update!(TenantSideConversationID: @side_conversation.ConversationID,
      MediatorID: users(:mediator1).UserID)
    assert_private_post_rejected
    @mediation.update!(MediatorID: @side_conversation.MediatorID, deleted_at: Time.current)
    assert_private_post_rejected
    assert_nil @side_conversation.reload.deleted_at
  end

  test "deleted message string and disabled assignment prevent posting" do
    log_in_as(@tenant)
    string = MessageString.find(@side_conversation.ConversationID)
    string.update!(deleted_at: Time.current)
    assert_private_post_rejected
    string.update!(deleted_at: nil)
    @mediation.update!(MediatorAssigned: false)
    assert_private_post_rejected
  end

  test "former mediator cannot post to a retired private conversation" do
    log_in_as(users(:mediator2))
    @mediation.update!(MediatorID: users(:mediator1).UserID, TenantSideConversationID: nil)
    assert_private_post_rejected
  end

  test "landlord can post only to their currently linked private conversation" do
    landlord = users(:landlord1)
    string = MessageString.create!(Role: "Side")
    side = SideMessageGroup.create!(ConversationID: string.ConversationID,
      UserID: landlord.UserID, MediatorID: @mediation.MediatorID)
    @mediation.update!(LandlordSideConversationID: side.ConversationID)
    log_in_as(landlord)
    assert_difference("Message.count", 1) do
      post mediator_messages_path, params: {
        conversation_id: side.ConversationID, Contents: "Landlord private message"
      }, as: :json
    end
    assert_response :success
    assert_equal @mediation.MediatorID, Message.order(:MessageID).last.recipientID
  end

  test "admin has no blanket private posting access" do
    log_in_as(users(:admin1))
    assert_private_post_rejected
  end

  private

  def assert_private_post_rejected
    assert_no_difference("Message.count") do
      assert_no_broadcasts("side_messages_#{@side_conversation.ConversationID}") do
        post mediator_messages_path, params: {
          conversation_id: @side_conversation.ConversationID, Contents: "Unavailable"
        }, as: :json
      end
    end
    assert_response :not_found
  end

  def with_stubbed_message_new(fake_message)
    original_new = Message.method(:new)
    Message.define_singleton_method(:new) { |_attrs| fake_message }
    yield
  ensure
    Message.define_singleton_method(:new, original_new)
  end
end
