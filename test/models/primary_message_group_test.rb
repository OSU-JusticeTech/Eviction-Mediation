require "test_helper"

class PrimaryMessageGroupTest < ActiveSupport::TestCase
  test "uses the correct table name and primary key" do
    assert_equal "PrimaryMessageGroups", PrimaryMessageGroup.table_name
    assert_equal "ConversationID", PrimaryMessageGroup.primary_key
  end

  test "validations require ConversationID, TenantID, LandlordID" do
    pmg = PrimaryMessageGroup.new
    assert_not pmg.valid?
    assert_includes pmg.errors.attribute_names.map(&:to_s), "ConversationID"
    assert_includes pmg.errors.attribute_names.map(&:to_s), "TenantID"
    assert_includes pmg.errors.attribute_names.map(&:to_s), "LandlordID"
  end

  
end
