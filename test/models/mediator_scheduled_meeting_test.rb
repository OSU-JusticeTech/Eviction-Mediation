require "test_helper"

class MediatorScheduledMeetingTest < ActiveSupport::TestCase
  setup do
    @mediator_id = 4

    @conversation = PrimaryMessageGroup.find_by!(
      MediatorID: @mediator_id
    )

    @conversation_id = @conversation.ConversationID

    MediatorScheduleAvailability.create!(
      MediatorID: @mediator_id,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )
  end

  def build_meeting(start_time: "2026-10-26 10:00:00",
                    end_time: "2026-10-26 10:30:00",
                    **attributes)
    MediatorScheduledMeeting.new(
      {
        MediatorID: @mediator_id,
        ConversationID: @conversation_id,
        StartTime: start_time,
        EndTime: end_time,
        Status: "scheduled"
      }.merge(attributes)
    )
  end

  test "accepts a valid meeting" do
    meeting = build_meeting

    assert meeting.valid?, meeting.errors.full_messages.join(", ")
  end

  test "rejects end time before start time" do
    meeting = build_meeting(
      start_time: "2026-10-26 11:00:00",
      end_time: "2026-10-26 10:00:00"
    )

    assert_not meeting.valid?
    assert meeting.errors[:EndTime].any?
  end

  test "rejects equal start and end times" do
    meeting = build_meeting(
      start_time: "2026-10-26 10:00:00",
      end_time: "2026-10-26 10:00:00"
    )

    assert_not meeting.valid?
    assert meeting.errors[:EndTime].any?
  end

  test "rejects overlapping meetings" do
    build_meeting.save!

    overlapping = build_meeting(
      start_time: "2026-10-26 10:15:00",
      end_time: "2026-10-26 10:45:00"
    )

    assert_not overlapping.valid?
    assert_includes overlapping.errors[:base],
                    "Mediator already has a meeting during this time"
  end

  test "allows back to back meetings" do
    build_meeting.save!

    next_meeting = build_meeting(
      start_time: "2026-10-26 10:30:00",
      end_time: "2026-10-26 11:00:00"
    )

    assert next_meeting.valid?,
           next_meeting.errors.full_messages.join(", ")
  end

  test "allows rebooking after cancellation" do
    original = build_meeting
    original.save!

    original.update!(Status: "canceled")

    replacement = build_meeting

    assert replacement.valid?,
           replacement.errors.full_messages.join(", ")
  end

  test "rejects meeting during blocked period" do
    MediatorScheduleBlock.create!(
      MediatorID: @mediator_id,
      StartTime: "2026-10-26 10:00:00",
      EndTime: "2026-10-26 11:00:00"
    )

    meeting = build_meeting

    assert_not meeting.valid?
    assert_includes meeting.errors[:base],
                    "Meeting overlaps with a blocked availability period"
  end

  test "allows meeting outside blocked period" do
    MediatorScheduleBlock.create!(
      MediatorID: @mediator_id,
      StartTime: "2026-10-26 13:00:00",
      EndTime: "2026-10-26 15:00:00"
    )

    meeting = build_meeting

    assert meeting.valid?,
           meeting.errors.full_messages.join(", ")
  end

  test "rejects meeting outside working hours" do
    meeting = build_meeting(
      start_time: "2026-10-26 18:00:00",
      end_time: "2026-10-26 18:30:00"
    )

    assert_not meeting.valid?
    assert_includes meeting.errors[:base],
                    "Meeting is outside mediator availability"
  end

  test "rejects meeting on unavailable day" do
    meeting = build_meeting(
      start_time: "2026-10-27 10:00:00",
      end_time: "2026-10-27 10:30:00"
    )

    assert_not meeting.valid?
    assert_includes meeting.errors[:base],
                    "Meeting is outside mediator availability"
  end

  test "rejects meetings crossing midnight" do
    meeting = build_meeting(
      start_time: "2026-10-26 23:30:00",
      end_time: "2026-10-27 00:30:00"
    )

    assert_not meeting.valid?
    assert_includes meeting.errors[:base],
                    "Meeting must start and end on the same day"
  end

  test "rejects invalid meeting status" do
    meeting = build_meeting(Status: "unknown")

    assert_not meeting.valid?
    assert meeting.errors[:Status].any?
  end

  test "rejects mediator not assigned to conversation" do
    other_conversation = PrimaryMessageGroup.where.not(
      MediatorID: @mediator_id
    ).first!

    meeting = build_meeting(
      ConversationID: other_conversation.ConversationID
    )

    assert_not meeting.valid?
    assert_includes meeting.errors[:MediatorID],
                    "must be assigned to this case"
  end

  test "requires start and end times" do
    meeting = build_meeting(
      StartTime: nil,
      EndTime: nil
    )

    assert_not meeting.valid?
    assert meeting.errors[:StartTime].any?
    assert meeting.errors[:EndTime].any?
  end
end