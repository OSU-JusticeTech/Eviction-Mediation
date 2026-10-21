require "test_helper"

class MediatorScheduleAvailabilityTest < ActiveSupport::TestCase
  test "accepts valid weekly availability" do
    availability = MediatorScheduleAvailability.new(
      MediatorID: 4,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    assert availability.valid?
  end

  test "rejects availability when end time is before start time" do
    availability = MediatorScheduleAvailability.new(
      MediatorID: 4,
      DayOfWeek: 1,
      StartTime: "17:00",
      EndTime: "09:00"
    )

    assert_not availability.valid?
    assert_includes availability.errors[:EndTime], "must be after the start time"
  end

  test "rejects invalid day of week" do
    availability = MediatorScheduleAvailability.new(
      MediatorID: 4,
      DayOfWeek: 7,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    assert_not availability.valid?
    assert availability.errors[:DayOfWeek].any?
  end

  test "requires start and end times" do
    availability = MediatorScheduleAvailability.new(
      MediatorID: 4,
      DayOfWeek: 1
    )

    assert_not availability.valid?
    assert availability.errors[:StartTime].any?
    assert availability.errors[:EndTime].any?
  end

  test "requires a mediator" do
    availability = MediatorScheduleAvailability.new(
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    assert_not availability.valid?
    assert availability.errors[:MediatorID].any?
  end

  test "requires a day of week" do
    availability = MediatorScheduleAvailability.new(
      MediatorID: 4,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    assert_not availability.valid?
    assert availability.errors[:DayOfWeek].any?
  end
end
