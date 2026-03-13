require "test_helper"

class SideMessageGroupTest < ActiveSupport::TestCase
  test "uses the correct table name and primary key" do
    assert_equal "SideMessageGroups", SideMessageGroup.table_name
    assert_equal "ConversationID", SideMessageGroup.primary_key
  end
end
