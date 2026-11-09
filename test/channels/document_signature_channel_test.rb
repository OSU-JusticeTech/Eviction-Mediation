require "test_helper"
require_relative "../support/cable_authorization_helpers"

class DocumentSignatureChannelTest < ActionCable::Channel::TestCase
  include CableAuthorizationHelpers
  setup do
    build_security_case
    @file = build_security_document
  end

  test "document viewers receive signature updates with unchanged payloads" do
    [@tenant, @landlord, @mediator].each do |user|
      subscribe_as user, file_id: @file.FileID
      stream = "document_#{@file.FileID}"
      assert_allowed stream
      connection.pubsub.broadcast(stream, tenant_signature: true)
      assert_equal [{ "tenant_signature" => true }], payloads
    end
  end

  test "anonymous outsiders and admins without viewing rights are rejected" do
    [nil, @outsider, @other_mediator, @admin].each do |user|
      subscribe_as user, file_id: @file.FileID
      assert_denied
    end
  end

  test "missing and user-deleted documents are rejected" do
    subscribe_as @landlord, file_id: 0
    assert_denied
    @file.update!(UserDeletedAt: Time.current)
    subscribe_as @landlord, file_id: @file.FileID
    assert_denied
  end

  test "reassignment revokes primary membership before delivery" do
    # Keep the wrong-type side membership: it must not preserve access.
    assert SideMessageGroup.exists?(ConversationID: @case.ConversationID, MediatorID: @mediator.UserID)
    assert_equal @file, FileDraft.find_viewable_by(@mediator, @file.FileID)
    subscribe_as @mediator, file_id: @file.FileID
    @case.update!(MediatorID: @other_mediator.UserID)
    assert_nil FileDraft.find_viewable_by(@mediator, @file.FileID)
    connection.pubsub.broadcast("document_#{@file.FileID}", tenant_signature: true)
    assert_empty payloads
    assert_empty subscription.send(:streams)
  end

  test "file deletion revokes even creator delivery without deleting stored data" do
    subscribe_as @landlord, file_id: @file.FileID
    @file.update!(UserDeletedAt: Time.current)
    connection.pubsub.broadcast("document_#{@file.FileID}", tenant_signature: true)
    assert_empty payloads
    assert_empty subscription.send(:streams)
    assert FileDraft.exists?(@file.FileID)
  end

  test "attachment removal revokes delivery" do
    subscribe_as @tenant, file_id: @file.FileID
    FileAttachment.where(FileID: @file.FileID).delete_all
    connection.pubsub.broadcast("document_#{@file.FileID}", tenant_signature: true)
    assert_empty payloads
    assert_empty subscription.send(:streams)
  end

  test "closure preserves document viewing and signature updates" do
    subscribe_as @tenant, file_id: @file.FileID
    @case.update!(deleted_at: Time.current)
    connection.pubsub.broadcast("document_#{@file.FileID}", tenant_signature: true)
    assert_equal [{ "tenant_signature" => true }], payloads
  end

  test "retired private attachments retain existing viewer rights" do
    file = build_security_document(conversation_id: @side.ConversationID)
    subscribe_as @mediator, file_id: file.FileID
    @case.update!(MediatorID: @other_mediator.UserID, TenantSideConversationID: nil)
    @side.update!(deleted_at: Time.current)
    MessageString.find(@side.ConversationID).update!(deleted_at: Time.current)
    connection.pubsub.broadcast("document_#{file.FileID}", tenant_signature: true)
    assert_equal [{ "tenant_signature" => true }], payloads
    subscribe_as @other_mediator, file_id: file.FileID
    assert_denied
  end

  %w[Primary Side].each do |role|
    test "#{role} document subscriptions reject overlapping wrong-type members" do
      file = build_document_role_overlap(role)
      [@outsider, @other_mediator].each do |user|
        subscribe_as user, file_id: file.FileID
        assert_denied
      end
      subscribe_as @tenant, file_id: file.FileID
      assert_allowed "document_#{file.FileID}"
    end
  end

  test "side membership revocation ignores an overlapping primary group before delivery" do
    file = build_document_role_overlap("Side")
    overlap = PrimaryMessageGroup.find(@side.ConversationID)
    overlap.update!(MediatorID: @mediator.UserID)
    subscribe_as @mediator, file_id: file.FileID
    assert_allowed "document_#{file.FileID}"
    @side.update!(MediatorID: @other_mediator.UserID)
    assert_nil FileDraft.find_viewable_by(@mediator, file.FileID)
    connection.pubsub.broadcast("document_#{file.FileID}", tenant_signature: true)
    assert_empty payloads
    assert_empty subscription.send(:streams)
  end
end
