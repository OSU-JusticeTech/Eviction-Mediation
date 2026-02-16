require "test_helper"

class MessageTest < ActiveSupport::TestCase
  test "uses the correct table name and primary key" do
    assert_equal "messages", Message.table_name
    assert_equal "MessageID", Message.primary_key
  end

  test "associations with file_attachments and file_drafts" do
    message = messages(:one)
    assert_respond_to message, :file_attachments
    assert_respond_to message, :file_drafts
    assert message.file_attachments.any?
  end
end
