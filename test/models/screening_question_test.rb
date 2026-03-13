require "test_helper"

class ScreeningQuestionTest < ActiveSupport::TestCase
  test "uses the correct table name and primary key" do
    assert_equal "ScreeningQuestions", ScreeningQuestion.table_name
    assert_equal "ScreeningID", ScreeningQuestion.primary_key
  end

  test "validates boolean inclusion for required fields" do
    sq = ScreeningQuestion.new
    assert_not sq.valid?
    # Each required boolean should produce an error when nil
    %w[InterpreterNeeded DisabilityAccommodation ConflictOfInterest SpeakOnOwnBehalf NeedToConsult Unsafe].each do |attr|
      assert_includes sq.errors.attribute_names.map(&:to_s), attr
    end
  end

  test "soft_delete! sets deleted_at and active? reflects it" do
    sq = ScreeningQuestion.new(
      UserID: users(:tenant1).UserID,
      InterpreterNeeded: true,
      DisabilityAccommodation: false,
      ConflictOfInterest: false,
      SpeakOnOwnBehalf: true,
      NeedToConsult: false,
      Unsafe: false
    )
    assert sq.valid?
    sq.save!
    assert sq.active?
    sq.soft_delete!
    assert_not sq.active?
    assert_not_nil sq.deleted_at
  end
end
