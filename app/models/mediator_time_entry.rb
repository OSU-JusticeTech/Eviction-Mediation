# One time-tracking session: a mediator clicks "Start Time Tracking" on a case
# and the session runs until they stop it, go idle, or log out. A case's total
# time is the sum of its finished sessions.
class MediatorTimeEntry < ApplicationRecord
  # No mouse movement for this long prompts "Are you still there?".
  IDLE_LIMIT = 15.minutes
  # How long the mediator has to answer the prompt before tracking stops.
  CONFIRM_WINDOW = 30.seconds
  # An active session with no heartbeat for this long was abandoned (tab or
  # browser closed without stopping), so it is closed at its last activity.
  STALE_AFTER = IDLE_LIMIT + CONFIRM_WINDOW + 1.minute

  belongs_to :mediator,
             class_name: "User",
             foreign_key: "MediatorID",
             primary_key: "UserID"

  belongs_to :conversation,
             class_name: "PrimaryMessageGroup",
             foreign_key: "ConversationID",
             primary_key: "ConversationID"

  validates :MediatorID, presence: true
  validates :ConversationID, presence: true
  validates :StartedAt, presence: true
  validates :LastActiveAt, presence: true

  validate :mediator_assigned_to_case, on: :create

  scope :active, -> { where(EndedAt: nil) }
  scope :finished, -> { where.not(EndedAt: nil) }

  # The mediator's running session, or nil. Abandoned sessions are closed at
  # their last heartbeat rather than credited with idle time.
  def self.current_for(mediator_id)
    entry = active.where(MediatorID: mediator_id).order(:StartedAt).last
    return nil unless entry

    if entry[:LastActiveAt] < STALE_AFTER.ago
      entry.close!(at: entry[:LastActiveAt])
      return nil
    end

    entry
  end

  # Starts a new session, closing any session the mediator has running on
  # another case so only one clock runs at a time.
  def self.start!(mediator_id, conversation_id)
    transaction do
      now = Time.current
      active.where(MediatorID: mediator_id).find_each { |entry| entry.close!(at: now) }
      create!(
        MediatorID: mediator_id,
        ConversationID: conversation_id,
        StartedAt: now,
        LastActiveAt: now
      )
    end
  end

  # { ConversationID => total seconds } across finished sessions.
  def self.totals_for(conversation_ids)
    finished.where(ConversationID: conversation_ids).group(:ConversationID).sum(:DurationSeconds)
  end

  def active?
    self[:EndedAt].nil?
  end

  def touch_activity!
    update!(LastActiveAt: Time.current)
  end

  def close!(at: Time.current)
    ended_at = [ at, self[:StartedAt] ].max
    update!(EndedAt: ended_at, DurationSeconds: (ended_at - self[:StartedAt]).round)
  end

  # The mediator didn't answer the "still there?" prompt. The idle minutes
  # before the prompt count; the time spent waiting on the prompt doesn't.
  def close_for_inactivity!
    close!(at: [ Time.current, self[:LastActiveAt] + IDLE_LIMIT ].min)
  end

  private

  def mediator_assigned_to_case
    return if self[:MediatorID].blank? || self[:ConversationID].blank?

    assigned = PrimaryMessageGroup.where(
      ConversationID: self[:ConversationID],
      MediatorID: self[:MediatorID]
    ).exists?

    unless assigned
      errors.add(:MediatorID, "must be assigned to this case")
    end
  end
end
