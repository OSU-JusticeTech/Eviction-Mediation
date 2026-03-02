require "test_helper"

class SurveyResponseTest < ActiveSupport::TestCase
  fixtures :users, :primary_message_groups

  def setup
    SurveyResponse.delete_all
    
    @user = users(:tenant1)
    @mediation = primary_message_groups(:one)
    @valid_attributes = {
      conversation_id: @mediation.ConversationID,
      user_id: @user.UserID,
      user_role: "Tenant",
      tool_ease: "easy",
      info_clear: "yes",
      understood_mediation: "yes",
      other_participated: "no",
      good_faith: "yes",
      helped_communicate: "yes",
      would_recommend: "yes",
      device_used: "computer"
    }
  end

  #INITIAL VALIDATION TEST
  test "valid with all correct attributes" do
    survey = SurveyResponse.new(@valid_attributes)
    assert survey.valid?, survey.errors.full_messages.inspect
  end

  #DATABASE TESTS
  test "invalid if a duplicate exists in the database" do
    SurveyResponse.create!(@valid_attributes)
    duplicate = SurveyResponse.new(@valid_attributes)
    
    assert_not duplicate.valid?, "Should be invalid because this user/mediation pair exists"
    assert_includes duplicate.errors[:user_id], "has already submitted a survey for this mediation"
  end

  test "data integrity: values remain consistent after database round-trip" do
    survey = SurveyResponse.create!(@valid_attributes)
    survey.reload

    assert_equal "Tenant", survey.user_role
    assert_equal "easy", survey.tool_ease
    assert_equal @user.UserID, survey.user_id
  end

  test "associations should remain intact after survey creation" do
    survey = SurveyResponse.create!(@valid_attributes)
    found_survey = SurveyResponse.find(survey.id)
    
    assert_equal @user.UserID, found_survey.user.UserID
    assert_equal @mediation.ConversationID, found_survey.primary_message_group.ConversationID
  end

  test "user and conversation_id match across database" do
    survey = SurveyResponse.create!(@valid_attributes)
    survey.reload
    assert_equal @user.UserID, survey.user_id
    assert_equal @mediation.ConversationID, survey.primary_message_group.ConversationID
  end

  #BUSINESS LOGIC TESTS
  test "invalid if user already submitted a survey for the same mediation" do
    SurveyResponse.create!(@valid_attributes)
    duplicate_survey = SurveyResponse.new(@valid_attributes)
    assert_not duplicate_survey.valid?
    assert_includes duplicate_survey.errors[:user_id], "has already submitted a survey for this mediation"
  end

  test "valid if user submits a survey for a different mediation" do
    SurveyResponse.create!(@valid_attributes)
    different_mediation = primary_message_groups(:two)
    new_survey = SurveyResponse.new(@valid_attributes.merge(conversation_id: different_mediation.ConversationID))
    assert new_survey.valid?
  end

  test "inclusion validations cover all multiple choice fields" do
    invalid_survey = SurveyResponse.new(@valid_attributes.merge(tool_ease: "crazy_hard"))
    assert_not invalid_survey.valid?, "Should reject values not in included FE dropdown"
  end

  #UNIQUENESS TESTS
  test "uniqueness: different users can submit surveys for the same mediation" do
    SurveyResponse.create!(@valid_attributes)
    other_user = users(:landlord1)
    new_survey = SurveyResponse.new(@valid_attributes.merge(user_id: other_user.UserID))
    assert new_survey.valid?, "A different user should be able to submit a survey for the same mediation but got errors: #{new_survey.errors.full_messages.inspect}"
  end


end
