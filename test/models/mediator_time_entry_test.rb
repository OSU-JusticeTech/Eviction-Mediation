require "test_helper"

class MediatorTimeEntryTest < ActiveSupport::TestCase
  setup do
    @mediator_id = 4
    @conversation = PrimaryMessageGroup.find_by!(MediatorID: @mediator_id)
    @conversation_id = @conversation.ConversationID
  end

  def create_entry(started_at: 1.hour.ago, last_active_at: started_at, ended_at: nil, conversation_id: @conversation_id)
    entry = MediatorTimeEntry.create!(
      MediatorID: @mediator_id,
      ConversationID: conversation_id,
      StartedAt: started_at,
      LastActiveAt: last_active_at
    )
    entry.close!(at: ended_at) if ended_at
    entry
  end

  test "requires mediator to be assigned to the case" do
    other_case = PrimaryMessageGroup.where.not(MediatorID: @mediator_id).first!
    entry = MediatorTimeEntry.new(
      MediatorID: @mediator_id,
      ConversationID: other_case.ConversationID,
      StartedAt: Time.current,
      LastActiveAt: Time.current
    )

    assert_not entry.valid?
    assert_includes entry.errors[:MediatorID], "must be assigned to this case"
  end

  test "start! creates an active entry" do
    entry = MediatorTimeEntry.start!(@mediator_id, @conversation_id)

    assert entry.active?
    assert_equal entry, MediatorTimeEntry.current_for(@mediator_id)
  end

  test "start! closes the mediator's running entry first" do
    previous = create_entry(started_at: 10.minutes.ago, last_active_at: 1.minute.ago)

    current = MediatorTimeEntry.start!(@mediator_id, @conversation_id)

    assert_not previous.reload.active?
    assert_in_delta 600, previous.DurationSeconds, 5
    assert_equal [ current ], MediatorTimeEntry.active.where(MediatorID: @mediator_id).to_a
  end

  test "close! records the duration" do
    started = 2.hours.ago
    entry = create_entry(started_at: started)

    entry.close!(at: started + 90.minutes)

    assert_equal 90 * 60, entry.DurationSeconds
    assert_not entry.active?
  end

  test "close_for_inactivity! credits idle time but not the confirm window" do
    last_active = 20.minutes.ago
    entry = create_entry(started_at: 1.hour.ago, last_active_at: last_active)

    entry.close_for_inactivity!

    assert_in_delta (last_active + MediatorTimeEntry::IDLE_LIMIT).to_i, entry.EndedAt.to_i, 1
  end

  test "close_for_inactivity! never ends in the future" do
    entry = create_entry(started_at: 30.minutes.ago, last_active_at: 1.minute.ago)

    entry.close_for_inactivity!

    assert_operator entry.EndedAt, :<=, Time.current
  end

  test "current_for closes abandoned entries at their last activity" do
    last_active = 1.hour.ago
    entry = create_entry(started_at: 2.hours.ago, last_active_at: last_active)

    assert_nil MediatorTimeEntry.current_for(@mediator_id)
    entry.reload
    assert_not entry.active?
    assert_in_delta last_active.to_i, entry.EndedAt.to_i, 1
    assert_in_delta 3600, entry.DurationSeconds, 1
  end

  test "totals_for sums only finished entries per case" do
    started = 3.hours.ago
    create_entry(started_at: started, ended_at: started + 30.minutes)
    create_entry(started_at: started, ended_at: started + 45.minutes)
    create_entry(started_at: 5.minutes.ago)

    totals = MediatorTimeEntry.totals_for([ @conversation_id ])

    assert_equal({ @conversation_id => 75 * 60 }, totals)
  end
end
