require "test_helper"

class MediatorScheduleBlockTest < ActiveSupport::TestCase
  test "accepts a valid blocked period" do
    block = MediatorScheduleBlock.new(
      MediatorID: 4,
      StartTime: "2026-10-26 13:00:00",
      EndTime: "2026-10-26 15:00:00",
      Reason: "Personal appointment"
    )

    assert block.valid?, block.errors.full_messages.join(", ")
  end

  test "rejects end time before start time" do
    block = MediatorScheduleBlock.new(
      MediatorID: 4,
      StartTime: "2026-10-26 15:00:00",
      EndTime: "2026-10-26 13:00:00"
    )

    assert_not block.valid?
    assert_includes block.errors[:EndTime], "must be after the start time"
  end

  test "rejects equal start and end times" do
    block = MediatorScheduleBlock.new(
      MediatorID: 4,
      StartTime: "2026-10-26 13:00:00",
      EndTime: "2026-10-26 13:00:00"
    )

    assert_not block.valid?
    assert block.errors[:EndTime].any?
  end

  test "requires start and end times" do
    block = MediatorScheduleBlock.new(MediatorID: 4)

    assert_not block.valid?
    assert block.errors[:StartTime].any?
    assert block.errors[:EndTime].any?
  end

  test "requires a mediator" do
    block = MediatorScheduleBlock.new(
      StartTime: "2026-10-26 13:00:00",
      EndTime: "2026-10-26 15:00:00"
    )

    assert_not block.valid?
    assert block.errors[:MediatorID].any?
  end

  test "reason is optional" do
    block = MediatorScheduleBlock.new(
      MediatorID: 4,
      StartTime: "2026-10-26 13:00:00",
      EndTime: "2026-10-26 15:00:00"
    )

    assert block.valid?, block.errors.full_messages.join(", ")
  end
end