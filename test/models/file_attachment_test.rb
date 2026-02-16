require "test_helper"

class FileAttachmentTest < ActiveSupport::TestCase
  #DATABASE TESTS
  test "uses the correct table name" do
    assert_equal "FileAttachments", FileAttachment.table_name
  end

  test "defines the correct composite primary key" do
    assert_equal ["FileID", "MessageID"], FileAttachment.primary_key
  end

  #BUSINESS LOGIC TESTS
  test "belongs to the correct message" do
    attachment = file_attachments(:one)
    assert_equal messages(:one), attachment.message
    assert_equal 1, attachment.MessageID
  end

  test "belongs to the correct file draft" do
    attachment = file_attachments(:two)
    assert_equal file_drafts(:two), attachment.file_draft
    assert_equal 2, attachment.FileID
  end

  test "is invalid without FileID or MessageID" do
    attachment = FileAttachment.new
    assert_not attachment.valid?
    assert attachment.errors[:FileID].any?
    assert attachment.errors[:MessageID].any?
  end

  #UNiQUENESS TESTS
  test "enforces uniqueness of the composite pair" do
    duplicate = FileAttachment.new(FileID: 1, MessageID: 1)
    assert_not duplicate.valid?, "Allowed a duplicate FileID and MessageID pair"
  end

end
