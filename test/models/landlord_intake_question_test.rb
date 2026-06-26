require "test_helper"

class LandlordIntakeQuestionTest < ActiveSupport::TestCase
  def valid_attrs
    {
      UserID: users(:landlord1).UserID,
      Reason: "Failure to Pay Rent",
      DesiredOutcome: "Receive Payment",
      AcceptPaymentPlan: false,
      AmountClaimed: 1500
    }
  end

  # --- Basic validations ---

  test "is valid with all required attributes" do
    assert LandlordIntakeQuestion.new(valid_attrs).valid?
  end

  test "is invalid without a reason" do
    liq = LandlordIntakeQuestion.new(valid_attrs.merge(Reason: ""))
    assert_not liq.valid?
    assert_includes liq.errors[:Reason], "must include at least one reason for the dispute"
  end

  test "is invalid with an unrecognised reason" do
    liq = LandlordIntakeQuestion.new(valid_attrs)
    liq.reasons = [ "Not A Real Reason" ]
    assert_not liq.valid?
    assert_includes liq.errors[:Reason], "contains an invalid selection"
  end

  test "is invalid with an unrecognised DesiredOutcome" do
    liq = LandlordIntakeQuestion.new(valid_attrs.merge(DesiredOutcome: "Burn It Down"))
    assert_not liq.valid?
  end

  test "MonthlyRent is optional and accepts nil" do
    liq = LandlordIntakeQuestion.new(valid_attrs.merge(MonthlyRent: nil))
    assert liq.valid?
  end

  test "MonthlyRent must be non-negative when provided" do
    liq = LandlordIntakeQuestion.new(valid_attrs.merge(MonthlyRent: -1))
    assert_not liq.valid?
    assert liq.errors[:MonthlyRent].any?
  end

  # --- Unknown-only bypass ---

  test "Unknown-only submission skips DesiredOutcome, AmountClaimed and other required-field validations" do
    liq = LandlordIntakeQuestion.new(UserID: users(:landlord1).UserID)
    liq.reasons = [ "Unknown" ]
    assert liq.valid?, liq.errors.full_messages.inspect
  end

  test "Unknown combined with other reasons does NOT bypass required-field validations" do
    liq = LandlordIntakeQuestion.new(UserID: users(:landlord1).UserID)
    liq.reasons = [ "Unknown", "Failure to Pay Rent" ]
    assert_not liq.valid?
    assert liq.errors[:DesiredOutcome].any?
  end

  test "normal reasons still enforce required-field validations" do
    liq = LandlordIntakeQuestion.new(UserID: users(:landlord1).UserID)
    liq.reasons = [ "Failure to Pay Rent" ]
    assert_not liq.valid?
    assert liq.errors[:AmountClaimed].any?
  end

  # --- Reason serialisation ---

  test "stores multiple reasons as a comma-separated string" do
    liq = LandlordIntakeQuestion.new(valid_attrs)
    liq.reasons = [ "Failure to Pay Rent", "Damage to Property" ]
    assert_equal "Failure to Pay Rent, Damage to Property", liq[:Reason]
  end

  test "reasons round-trips through the setter and getter" do
    selected = [ "Expiration of Lease", "Illegal Activity" ]
    liq = LandlordIntakeQuestion.new(valid_attrs)
    liq.reasons = selected
    assert_equal selected, liq.reasons
  end

  test "excludes tenant-only reasons from its REASONS list" do
    excluded = [ "Unlivable", "Unsafe", "Failure to Repair", "My Rent Will be Late" ]
    excluded.each do |reason|
      assert_not_includes LandlordIntakeQuestion::REASONS, reason
    end
    (IntakeQuestion::REASONS - excluded).each do |reason|
      assert_includes LandlordIntakeQuestion::REASONS, reason
    end
  end
end
