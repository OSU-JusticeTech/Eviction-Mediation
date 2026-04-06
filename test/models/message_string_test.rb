require "test_helper"

class MessageStringTest < ActiveSupport::TestCase
  test "uses the correct table name and primary key" do
    assert_equal "MessageStrings", MessageString.table_name
    assert_equal "ConversationID", MessageString.primary_key
  end

  test "has LastMessageSentDate tracking" do
    ms = message_strings(:one)
    assert_not_nil ms.LastMessageSentDate
  end
end
