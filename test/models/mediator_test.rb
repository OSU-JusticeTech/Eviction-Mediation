require "test_helper"

class MediatorTest < ActiveSupport::TestCase
  test "uses the correct table name" do
    assert_equal "Mediators", Mediator.table_name
  end

  test "uses UserID as the primary key" do
    assert_equal "UserID", Mediator.primary_key
  end

end
