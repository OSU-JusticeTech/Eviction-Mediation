require "test_helper"
require_relative "../support/cable_authorization_helpers"

class MediatorMessagesChannelTest < ActionCable::Channel::TestCase
  include CableAuthorizationHelpers
  setup { build_security_case }

  test "only the party and current mediator can subscribe and receive" do
    [@tenant, @mediator].each do |user|
      subscribe_as user, conversation_id: @side.ConversationID
      stream = "side_messages_#{@side.ConversationID}"
      assert_allowed stream
      connection.pubsub.broadcast(stream, contents: "Private")
      assert_equal [{ "contents" => "Private" }], payloads
    end
    [nil, @landlord, @outsider, @other_mediator, @admin].each do |user|
      subscribe_as user, conversation_id: @side.ConversationID
      assert_denied
    end
  end

  test "missing deleted and wrong-role records are rejected before streaming" do
    subscribe_as @tenant, conversation_id: 0
    assert_denied
    string = MessageString.find(@side.ConversationID)
    string.update!(Role: "Primary")
    subscribe_as @tenant, conversation_id: @side.ConversationID
    assert_denied
    string.update!(Role: "Side", deleted_at: Time.current)
    subscribe_as @tenant, conversation_id: @side.ConversationID
    assert_denied
    string.update!(deleted_at: nil)
    @side.update!(deleted_at: Time.current)
    subscribe_as @tenant, conversation_id: @side.ConversationID
    assert_denied
  end

  test "landlord private conversation is restricted to landlord and current mediator" do
    string = MessageString.create!(Role: "Side")
    side = SideMessageGroup.create!(ConversationID: string.ConversationID,
      UserID: @landlord.UserID, MediatorID: @mediator.UserID)
    @case.update!(LandlordSideConversationID: side.ConversationID)
    [@landlord, @mediator].each do |user|
      subscribe_as user, conversation_id: side.ConversationID
      assert_allowed "side_messages_#{side.ConversationID}"
    end
    subscribe_as @tenant, conversation_id: side.ConversationID
    assert_denied
  end

  test "reassignment retires old streams and limits replacement streams to new participants" do
    old = subscribe_as @mediator, conversation_id: @side.ConversationID
    old_connection = connection
    party = subscribe_as @tenant, conversation_id: @side.ConversationID
    party_connection = connection
    string = MessageString.create!(Role: "Side")
    replacement = SideMessageGroup.create!(ConversationID: string.ConversationID,
      UserID: @tenant.UserID, MediatorID: @other_mediator.UserID)
    @case.update!(MediatorID: @other_mediator.UserID, TenantSideConversationID: replacement.ConversationID)
    [old_connection, party_connection].each do |cable|
      cable.pubsub.broadcast("side_messages_#{@side.ConversationID}", contents: "Retired")
    end
    assert_empty payloads(old)
    assert_empty payloads(party)
    assert_empty old.send(:streams)
    assert_empty party.send(:streams)
    [@mediator, @tenant].each do |user|
      subscribe_as user, conversation_id: @side.ConversationID
      assert_denied
    end
    subscribe_as @mediator, conversation_id: replacement.ConversationID
    assert_denied
    [@other_mediator, @tenant].each do |user|
      subscribe_as user, conversation_id: replacement.ConversationID
      assert_allowed "side_messages_#{replacement.ConversationID}"
    end
    assert_nil @side.reload.deleted_at
    assert_nil MessageString.find(@side.ConversationID).deleted_at
  end

  test "closure blocks delivery despite nondeleted side records" do
    subscribe_as @mediator, conversation_id: @side.ConversationID
    @case.update!(deleted_at: Time.current)
    connection.pubsub.broadcast("side_messages_#{@side.ConversationID}", contents: "Closed")
    assert_empty payloads
    assert_empty subscription.send(:streams)
    subscribe_as @tenant, conversation_id: @side.ConversationID
    assert_denied
  end
end
