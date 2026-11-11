require "test_helper"
require_relative "../support/cable_authorization_helpers"

class FileDraftTest < ActiveSupport::TestCase
  include CableAuthorizationHelpers

  #DATABASE TESTS
  test "uses the correct table name and primary key" do
    assert_equal "FileDrafts", FileDraft.table_name
    assert_equal "FileID", FileDraft.primary_key
  end

  test "has many file_attachments" do
    draft = file_drafts(:one)
    assert_respond_to draft, :file_attachments
    assert_equal 1, draft.file_attachments.count
  end

  test "has many messages through file_attachments" do
    draft = file_drafts(:one)
    assert_includes draft.messages, messages(:one)
  end

  #BUSINESS LOGIC TESTS
  test "human_file_size formats the stored file size" do
    previous = Rails.application.config.x.document_storage
    root = Dir.mktmpdir("document-size-", Rails.root.join("tmp"))
    Rails.application.config.x.document_storage = DocumentStorageConfiguration.new(
      root: root, public_root: Rails.root.join("public")
    )
    locator = DocumentStorage.configured.allocate_private_locator(extension: "pdf")
    File.write(File.join(root, locator.delete_prefix(DocumentStorage::PRIVATE_PREFIX)), "a" * 2048)

    assert_equal "2 KB", FileDraft.new(FileURLPath: locator).human_file_size
  ensure
    Rails.application.config.x.document_storage = previous
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  test "human_file_size is nil when the file cannot be read" do
    assert_nil FileDraft.new(FileURLPath: "privateDocuments/missing.pdf").human_file_size
  end

  test "uploaded_at returns CreatedAt if present" do
    fixed_time = Time.zone.parse("2025-01-01 00:00:00")
    draft = FileDraft.new(CreatedAt: fixed_time)
    assert_equal fixed_time, draft.uploaded_at
  end

  test "uploaded_at returns nil when CreatedAt is nil" do
    draft = FileDraft.new(CreatedAt: nil)
    assert_nil draft.uploaded_at
  end

  test "correctly reads file metadata from fixtures" do
    draft = file_drafts(:one)
    assert_equal "test", draft.FileName
    assert_equal "doc", draft.FileTypes
    assert_equal "home/docs/example", draft.FileURLPath
  end
  test "shared viewing lookup preserves creator and primary participant access" do
    build_security_case
    file = build_security_document
    [@landlord, @tenant, @mediator].each do |user|
      assert_equal file, FileDraft.find_viewable_by(user, file.FileID)
    end
    [nil, @outsider, @other_mediator, @admin].each do |user|
      assert_nil FileDraft.find_viewable_by(user, file.FileID)
    end
    @case.update!(deleted_at: Time.current, MediatorAssigned: false)
    assert_equal file, FileDraft.find_viewable_by(@mediator, file.FileID)
    file.update!(UserDeletedAt: Time.current)
    assert_nil FileDraft.find_viewable_by(@landlord, file.FileID)
    assert_nil FileDraft.find_viewable_by(@tenant, file.FileID)
  end

  test "direct sender and recipient retain access without conversation membership" do
    build_security_case
    file = build_security_document
    message = file.messages.first
    message.update!(SenderID: @outsider.UserID, recipientID: @other_mediator.UserID)
    assert_equal file, FileDraft.find_viewable_by(@outsider, file.FileID)
    assert_equal file, FileDraft.find_viewable_by(@other_mediator, file.FileID)
  end

  test "creator needs no attachment and unrelated admin gets no override" do
    file = FileDraft.create!(CreatorID: users(:admin1).UserID, FileName: "Private",
      FileTypes: "html", FileURLPath: "private.html")
    assert_equal file, FileDraft.find_viewable_by(users(:admin1), file.FileID)
    assert_nil FileDraft.find_viewable_by(users(:tenant1), file.FileID)
    assert_nil FileDraft.find_viewable_by(users(:admin1), 0)
  end

  %w[Primary Side].each do |role|
    test "#{role} documents ignore overlapping wrong-type group membership" do
      build_security_case
      file = build_document_role_overlap(role)
      [@tenant, @mediator].each do |user|
        assert_equal file, FileDraft.find_viewable_by(user, file.FileID)
      end
      [@outsider, @other_mediator].each do |user|
        assert_nil FileDraft.find_viewable_by(user, file.FileID)
      end
    end
  end

  test "null role denies group membership while preserving creator and direct participants" do
    build_security_case
    file = build_security_document
    MessageString.find(@case.ConversationID).update!(Role: nil)
    assert_nil FileDraft.find_viewable_by(@tenant, file.FileID)
    assert_nil FileDraft.find_viewable_by(@mediator, file.FileID)
    assert_equal file, FileDraft.find_viewable_by(@landlord, file.FileID)
    file.messages.first.update!(SenderID: @outsider.UserID, recipientID: @other_mediator.UserID)
    [@outsider, @other_mediator].each do |user|
      assert_equal file, FileDraft.find_viewable_by(user, file.FileID)
    end
    file.update!(UserDeletedAt: Time.current)
    [@landlord, @outsider, @other_mediator].each do |user|
      assert_nil FileDraft.find_viewable_by(user, file.FileID)
    end
  end

  test "missing conversation string and unknown role deny group membership" do
    build_security_case
    file = build_security_document
    # Missing strings and unknown roles cannot normally be persisted under the
    # foreign key and role check constraints; simulate their lookup results.
    original_where = MessageString.method(:where)
    begin
      {
        "missing conversation string" => [],
        "unknown role" => [MessageString.new(ConversationID: @case.ConversationID, Role: "Unknown")]
      }.each do |scenario, strings|
        MessageString.define_singleton_method(:where) { |*args, **kwargs| strings }
        assert_nil FileDraft.find_viewable_by(@tenant, file.FileID), scenario
        assert_nil FileDraft.find_viewable_by(@mediator, file.FileID), scenario
        assert_equal file, FileDraft.find_viewable_by(@landlord, file.FileID), scenario
      end
    ensure
      MessageString.define_singleton_method(:where) { |*args, **kwargs, &block| original_where.call(*args, **kwargs, &block) }
    end
  end

  test "multiple attachments grant access through any correctly typed conversation only" do
    build_security_case
    file = build_document_role_overlap("Primary")
    string = MessageString.create!(Role: "Side")
    SideMessageGroup.create!(ConversationID: string.ConversationID,
      UserID: @outsider.UserID, MediatorID: @mediator.UserID)
    message = Message.create!(ConversationID: string.ConversationID,
      SenderID: @mediator.UserID, Contents: "Shared document")
    attachment = FileAttachment.create!(FileID: file.FileID, MessageID: message.MessageID)
    assert_equal file, FileDraft.find_viewable_by(@tenant, file.FileID)
    assert_equal file, FileDraft.find_viewable_by(@outsider, file.FileID)
    assert_nil FileDraft.find_viewable_by(@other_mediator, file.FileID)
    attachment.destroy!
    assert_nil FileDraft.find_viewable_by(@outsider, file.FileID)
    assert_equal file, FileDraft.find_viewable_by(@tenant, file.FileID)
  end

  test "historical private documents retain side membership without an active mediation" do
    build_security_case
    file = build_document_role_overlap("Side")
    @side.update!(deleted_at: Time.current)
    MessageString.find(@side.ConversationID).update!(deleted_at: Time.current)
    @case.update!(deleted_at: Time.current, MediatorID: @other_mediator.UserID,
      TenantSideConversationID: nil)
    [@tenant, @mediator].each do |user|
      assert_equal file, FileDraft.find_viewable_by(user, file.FileID)
    end
    [@outsider, @other_mediator].each do |user|
      assert_nil FileDraft.find_viewable_by(user, file.FileID)
    end
  end
end
