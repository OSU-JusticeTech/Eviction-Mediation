require "test_helper"
require "tmpdir"
require "stringio"
require "minitest/mock"

class DocumentDeletionTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("document-deletion-")
    @storage = DocumentStorage.new(configuration: DocumentStorageConfiguration.new(
      root: @root, public_root: Rails.root.join("public")
    ))
    @file = file_drafts(:one)
    @user = User.find(@file.CreatorID)
    @locator = @storage.store(io: StringIO.new("original"), extension: "txt")
    @file.update!(FileURLPath: @locator)
    @attachments = FileAttachment.where(FileID: @file.FileID).pluck(:MessageID)
    @attributes = @file.reload.attributes
    @log = StringIO.new
    @deletion = DocumentDeletion.new(logger: Logger.new(@log))
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "authorized deletion removes attachments but preserves messages conversations and agreement metadata" do
    messages = Message.count
    conversations = PrimaryMessageGroup.count
    @file.update!(AgreementTemplate: "a", AgreementVersion: 1, AgreementTerms: '{"address":"original"}')
    assert @deletion.call(id: @file.FileID, user: @user)
    assert @file.reload.UserDeletedAt
    assert_empty FileAttachment.where(FileID: @file.FileID)
    assert_equal messages, Message.count
    assert_equal conversations, PrimaryMessageGroup.count
    assert_equal "a", @file.AgreementTemplate
    assert_equal 1, @file.AgreementVersion
    assert_equal({ "address" => "original" }, @file.agreement_terms)
    assert_equal @locator, @file.FileURLPath
    assert_bytes
  end

  test "unauthorized deletion leaves all references intact" do
    assert_raises(DocumentDeletion::Unauthorized) do
      @deletion.call(id: @file.FileID, user: users(:tenant2))
    end
    assert_unchanged
  end

  test "authorization uses current creator under a database lock" do
    # The original creator is also conversation one's landlord. Use a
    # conversation they do not participate in so ownership is their only grant.
    message = Message.find(@attachments.first)
    message.update!(ConversationID: primary_message_groups(:two).ConversationID)
    new_creator_id = users(:tenant2).UserID
    FileDraft.where(FileID: @file.FileID).update_all(CreatorID: new_creator_id)
    assert_equal @user.UserID, @file.CreatorID
    assert_equal new_creator_id, FileDraft.find(@file.FileID).CreatorID
    @attributes = @attributes.merge("CreatorID" => new_creator_id)

    assert_raises(DocumentDeletion::Unauthorized) do
      @deletion.call(id: @file.FileID, user: @user)
    end
    assert_unchanged
  end

  test "former creator retains deletion permission as a conversation party" do
    FileDraft.where(FileID: @file.FileID).update_all(CreatorID: users(:tenant2).UserID)

    assert @deletion.call(id: @file.FileID, user: @user)
    assert @file.reload.UserDeletedAt
    assert_empty FileAttachment.where(FileID: @file.FileID)
    assert_bytes
  end

  test "database failure after attachment removal restores original references" do
    relation = FileDraft.where(FileID: @file.FileID)
    relation.stub(:find_by, @file) do
      FileDraft.stub(:lock, relation) do
        @file.stub(:update!, ->(*) { raise ActiveRecord::RecordInvalid.new(@file) }) do
          assert_raises(DocumentDeletion::Failure) { delete_document }
        end
      end
    end
    assert_unchanged
  end

  test "attachment destruction veto rolls back the entire deletion" do
    attachment = FileAttachment.where(FileID: @file.FileID).first!
    relation = FileAttachment.where(FileID: @file.FileID)
    relation.stub(:each, ->(&block) { block.call(attachment) }) do
      FileAttachment.stub(:where, relation) do
        attachment.stub(:destroy!, -> { raise ActiveRecord::RecordNotDestroyed }) do
          assert_raises(DocumentDeletion::Failure) { delete_document }
        end
      end
    end
    assert_unchanged
  end

  test "enclosing rollback restores document and attachments and preserves bytes" do
    FileDraft.transaction(requires_new: true) do
      delete_document
      assert_bytes
      raise ActiveRecord::Rollback
    end
    assert_unchanged
  end

  test "explicit rollback cannot be returned as success" do
    relation = FileDraft.where(FileID: @file.FileID)
    relation.stub(:find_by, ->(*) { raise ActiveRecord::Rollback }) do
      FileDraft.stub(:lock, relation) do
        assert_raises(DocumentDeletion::Failure) { delete_document }
      end
    end
    assert_unchanged
  end

  test "private cleanup retains shared and soft deleted locator references" do
    other = file_drafts(:two)
    other.update!(FileURLPath: @locator)
    delete_document
    @deletion.send(:cleanup, @locator)
    assert_bytes
    other.update!(UserDeletedAt: Time.current)
    @deletion.send(:cleanup, @locator)
    assert_bytes
  end

  test "legacy cleanup never resolves or deletes public files" do
    @file.update!(FileURLPath: "userFiles/original.txt")
    DocumentStorage.stub(:configured, -> { flunk "legacy deletion accessed storage" }) do
      delete_document
      @deletion.send(:cleanup, @file.FileURLPath)
    end
    assert_equal "userFiles/original.txt", @file.reload.FileURLPath
    assert @file.UserDeletedAt
  end

  test "missing physical file does not prevent database deletion" do
    File.delete(@storage.resolve(@locator))
    delete_document
    assert @file.reload.UserDeletedAt
    assert_empty FileAttachment.where(FileID: @file.FileID)
  end

  test "cleanup failure is logged without reversing database success" do
    delete_document
    FileDraft.stub(:unscoped, -> { raise ActiveRecord::StatementInvalid, "cleanup query failed" }) do
      @deletion.send(:cleanup, @locator)
    end
    assert_includes @log.string, "cleanup failed locator=#{@locator}"
    assert @file.reload.UserDeletedAt
    assert_bytes
  end

  test "unreferenced private bytes are deferred because writers do not share a locator lock" do
    @file.update!(FileURLPath: "userFiles/other.txt")
    @deletion.send(:cleanup, @locator)
    assert_includes @log.string, "cleanup deferred locator=#{@locator}"
    assert_bytes
  end

  private

  def delete_document
    @deletion.call(id: @file.FileID, user: @user)
  end

  def assert_bytes
    assert_equal "original", @storage.resolve(@locator).binread
  end

  def assert_unchanged
    assert_equal @attributes, @file.reload.attributes
    assert_equal @attachments, FileAttachment.where(FileID: @file.FileID).pluck(:MessageID)
    assert_bytes
  end
end
