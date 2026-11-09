require "test_helper"
require_relative "../support/cable_authorization_helpers"

class MessagesChannelTest < ActionCable::Channel::TestCase
  include CableAuthorizationHelpers
  setup { build_security_case }

  test "tenant landlord assigned mediator and admin receive unchanged payloads" do
    [@tenant, @landlord, @mediator, @admin].each do |user|
      subscribe_as user, conversation_id: @case.ConversationID
      stream = "messages_#{@case.ConversationID}"
      assert_allowed stream
      connection.pubsub.broadcast(stream, contents: "Hello", attachments: [])
      assert_equal [{ "contents" => "Hello", "attachments" => [] }], payloads
    end
  end

  test "anonymous unrelated users and unrelated mediators are rejected" do
    [nil, @outsider, @other_mediator].each do |user|
      subscribe_as user, conversation_id: @case.ConversationID
      assert_denied
    end
  end

  test "assignment flag is required" do
    @case.update!(MediatorAssigned: false)
    subscribe_as @mediator, conversation_id: @case.ConversationID
    assert_denied
  end

  test "pending parties are denied but admin retains visibility" do
    @case.update!(accepted_by_tenant: false)
    subscribe_as @tenant, conversation_id: @case.ConversationID
    assert_denied
    subscribe_as @admin, conversation_id: @case.ConversationID
    assert_allowed "messages_#{@case.ConversationID}"
  end

  test "missing deleted and wrong-role conversation records are rejected" do
    subscribe_as @tenant, conversation_id: 0
    assert_denied
    string = MessageString.find(@case.ConversationID)
    string.update!(Role: "Side")
    subscribe_as @tenant, conversation_id: @case.ConversationID
    assert_denied
    string.update!(Role: "Primary", deleted_at: Time.current)
    subscribe_as @tenant, conversation_id: @case.ConversationID
    assert_denied
    string.update!(deleted_at: nil)
    @case.update!(deleted_at: Time.current)
    subscribe_as @tenant, conversation_id: @case.ConversationID
    assert_denied
  end

  test "reassignment suppresses queued payloads without stopping another subscription" do
    old = subscribe_as @mediator, conversation_id: @case.ConversationID
    old_connection = connection
    stream = "messages_#{@case.ConversationID}"
    queued = connection.pubsub.callbacks[stream].first
    file = build_security_document
    file.update!(CreatorID: @mediator.UserID)
    document = subscribe_as @mediator, { file_id: file.FileID },
      channel_class: DocumentSignatureChannel, cable_connection: old_connection
    @case.update!(MediatorID: @other_mediator.UserID)
    queued.call(ActiveSupport::JSON.encode(contents: "Confidential"))
    assert_empty payloads(old)
    assert_empty old.send(:streams)
    old_connection.pubsub.broadcast("document_#{file.FileID}", signed: true)
    assert_equal [{ "signed" => true }], payloads(document)
    subscribe_as @other_mediator, conversation_id: @case.ConversationID
    assert_allowed stream
    subscribe_as @mediator, conversation_id: @case.ConversationID
    assert_denied
    # Queued handlers must not revive even if permission is subsequently restored.
    @case.update!(MediatorID: @mediator.UserID)
    queued.call(ActiveSupport::JSON.encode(contents: "Queued"))
    assert_empty payloads(old)
  end

  test "admin role revocation is checked before transmitting" do
    subscribe_as @admin, conversation_id: @case.ConversationID
    @admin.update!(Role: "Mediator")
    connection.pubsub.broadcast("messages_#{@case.ConversationID}", contents: "Restricted")
    assert_empty payloads
    assert_empty subscription.send(:streams)
  end

  test "closure suppresses delivery and prevents new subscriptions" do
    subscribe_as @tenant, conversation_id: @case.ConversationID
    @case.update!(deleted_at: Time.current)
    connection.pubsub.broadcast("messages_#{@case.ConversationID}", contents: "After closure")
    assert_empty payloads
    assert_empty subscription.send(:streams)
    subscribe_as @tenant, conversation_id: @case.ConversationID
    assert_denied
  end
end
