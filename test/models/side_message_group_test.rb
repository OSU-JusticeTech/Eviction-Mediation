require "test_helper"
require_relative "../support/cable_authorization_helpers"

class SideMessageGroupTest < ActiveSupport::TestCase
  include CableAuthorizationHelpers

  test "uses the correct table name and primary key" do
    assert_equal "SideMessageGroups", SideMessageGroup.table_name
    assert_equal "ConversationID", SideMessageGroup.primary_key
  end
  test "live private access requires current matching case participants" do
    build_security_case
    [@tenant, @mediator].each do |user|
      assert_equal @side, SideMessageGroup.find_live_for(user, @side.ConversationID)
    end
    [nil, @landlord, @outsider, @other_mediator, @admin].each do |user|
      assert_nil SideMessageGroup.find_live_for(user, @side.ConversationID)
    end
    @case.update!(MediatorAssigned: false)
    assert_nil SideMessageGroup.find_live_for(@mediator, @side.ConversationID)
  end

  test "retirement and closure block live access without removing history or documents" do
    build_security_case
    file = build_security_document(conversation_id: @side.ConversationID)
    message_ids = Message.where(ConversationID: @side.ConversationID).pluck(:MessageID)
    @case.update!(MediatorID: @other_mediator.UserID, TenantSideConversationID: nil)
    assert_nil SideMessageGroup.find_live_for(@mediator, @side.ConversationID)
    assert_nil SideMessageGroup.find_live_for(@tenant, @side.ConversationID)
    assert_equal file, FileDraft.find_viewable_by(@mediator, file.FileID)
    assert_equal message_ids, Message.where(ConversationID: @side.ConversationID).pluck(:MessageID)
    assert_nil @side.reload.deleted_at
    @case.update!(MediatorID: @mediator.UserID, TenantSideConversationID: @side.ConversationID,
      deleted_at: Time.current)
    assert_nil SideMessageGroup.find_live_for(@tenant, @side.ConversationID)
    assert_equal file, FileDraft.find_viewable_by(@mediator, file.FileID)
  end

  test "wrong party link and deleted parent string deny access" do
    build_security_case
    @case.update!(TenantSideConversationID: nil, LandlordSideConversationID: @side.ConversationID)
    assert_nil SideMessageGroup.find_live_for(@tenant, @side.ConversationID)
    @case.update!(TenantSideConversationID: @side.ConversationID, LandlordSideConversationID: nil)
    MessageString.find(@case.ConversationID).update!(deleted_at: Time.current)
    assert_nil SideMessageGroup.find_live_for(@tenant, @side.ConversationID)
  end
end
