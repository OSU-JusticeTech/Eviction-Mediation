require "test_helper"

#This currently includes no unit testing, simply config tests, the model should be updated to include a link between mediators and conversations, and then the tests should be updated to reflect that.
class ConversationMediatorTest < ActiveSupport::TestCase
  test "configuration: uses the correct legacy table name" do
    assert_equal "ConversationMediators", ConversationMediator.table_name
  end

  test "configuration: uses the custom primary key" do
    assert_equal "MediatedConversationID", ConversationMediator.primary_key
  end

  test "identity: can find a record by the custom primary key" do
    mediator = ConversationMediator.create!(MediatedConversationID: 500)
    
    assert_equal 500, mediator.id
    assert_equal mediator, ConversationMediator.find(500)
  end
end
