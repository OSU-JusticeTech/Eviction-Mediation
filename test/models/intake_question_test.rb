require "test_helper"

class IntakeQuestionTest < ActiveSupport::TestCase
  def valid_attrs
    {
      UserID: users(:tenant1).UserID,
      Reason: "Failure to Pay Rent",
      BestOption: "Pay Missed Rent",
      Section8: false,
      MoneyOwed: 1000,
      TotalCostOrMonthly: true,
      PayableToday: 50
    }
  end

  # --- Basic validations ---

  test "is valid with all required attributes" do
    assert IntakeQuestion.new(valid_attrs).valid?
  end

  test "is invalid without a reason" do
    iq = IntakeQuestion.new(valid_attrs.merge(Reason: ""))
    assert_not iq.valid?
    assert_includes iq.errors[:Reason], "must include at least one reason for the dispute"
  end

  test "is invalid with an unrecognised reason" do
    iq = IntakeQuestion.new(valid_attrs)
    iq.reasons = [ "Not A Real Reason" ]
    assert_not iq.valid?
    assert_includes iq.errors[:Reason], "contains an invalid selection"
  end

  test "is invalid with an unrecognised BestOption" do
    iq = IntakeQuestion.new(valid_attrs.merge(BestOption: "Disappear"))
    assert_not iq.valid?
  end

  test "MonthlyRent is required when TotalCostOrMonthly is false" do
    iq = IntakeQuestion.new(valid_attrs.merge(TotalCostOrMonthly: false, MonthlyRent: nil))
    assert_not iq.valid?
    assert iq.errors[:MonthlyRent].any?
  end

  test "MonthlyRent must be absent when TotalCostOrMonthly is true" do
    iq = IntakeQuestion.new(valid_attrs.merge(TotalCostOrMonthly: true, MonthlyRent: 800))
    assert_not iq.valid?
    assert iq.errors[:MonthlyRent].any?
  end

  # --- Unknown-only bypass ---

  test "Unknown-only submission skips BestOption, MoneyOwed and other required-field validations" do
    iq = IntakeQuestion.new(UserID: users(:tenant1).UserID)
    iq.reasons = [ "Unknown" ]
    assert iq.valid?, iq.errors.full_messages.inspect
  end

  test "Unknown combined with other reasons does NOT bypass required-field validations" do
    iq = IntakeQuestion.new(UserID: users(:tenant1).UserID)
    iq.reasons = [ "Unknown", "Failure to Pay Rent" ]
    assert_not iq.valid?
    assert iq.errors[:BestOption].any?
  end

  test "normal reasons still enforce required-field validations" do
    iq = IntakeQuestion.new(UserID: users(:tenant1).UserID)
    iq.reasons = [ "Failure to Pay Rent" ]
    assert_not iq.valid?
    assert iq.errors[:MoneyOwed].any?
  end

  # --- Reason serialisation ---

  test "stores multiple reasons as a comma-separated string" do
    iq = IntakeQuestion.new(valid_attrs)
    iq.reasons = [ "Failure to Pay Rent", "Unsafe", "Illegal Activity" ]
    assert_equal "Failure to Pay Rent, Unsafe, Illegal Activity", iq[:Reason]
  end

  test "reasons round-trips through the setter and getter" do
    selected = [ "Damage to Property", "Nuisance or Disturbance" ]
    iq = IntakeQuestion.new(valid_attrs)
    iq.reasons = selected
    assert_equal selected, iq.reasons
  end
end
