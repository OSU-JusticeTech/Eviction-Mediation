require "test_helper"

class UserActivityLogTest < ActiveSupport::TestCase
  test "uses the correct table name and primary key" do
    assert_equal "UserActivityLogs", UserActivityLog.table_name
    assert_equal "LogID", UserActivityLog.primary_key
  end
end
