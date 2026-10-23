class MediatorScheduledMeeting < ApplicationRecord
  belongs_to :mediator,
             foreign_key: "MediatorID",
             primary_key: "UserID"

  belongs_to :conversation,
             class_name: "PrimaryMessageGroup",
             foreign_key: "ConversationID",
             primary_key: "ConversationID"

  validates :MediatorID, presence: true
  validates :ConversationID, presence: true
  validates :StartTime, presence: true
  validates :EndTime, presence: true
  validates :Status, inclusion: {
    in: %w[scheduled canceled completed]
  }

  validate :end_after_start
  validate :mediator_assigned_to_case
  validate :no_overlapping_meetings
  validate :not_during_blocked_period
  validate :within_mediator_availability

  after_save_commit :send_meeting_notifications

  # A snapshot invalidates old reminders without adding a database column.
  def reminder_version
    [ updated_at.utc.iso8601(6), self[:StartTime].utc.iso8601(6), self[:EndTime].utc.iso8601(6),
      self[:ZoomLink], self[:ConversationID], self[:MediatorID] ]
  end

  def notification_recipients
    recipients = [ conversation.tenant, conversation.landlord ]
    recipients << User.find_by(UserID: self[:MediatorID])
    recipients.compact.uniq(&:UserID)
  end

  private

  def send_meeting_notifications
    return if conversation.past? || conversation.MediatorID != self[:MediatorID]

    event = if self[:Status] == "canceled" && saved_change_to_Status?
      "canceled"
    elsif self[:Status] == "scheduled"
      if previously_new_record? || saved_change_to_Status?
        "scheduled"
      elsif saved_change_to_StartTime? || saved_change_to_EndTime?
        "rescheduled"
      elsif saved_change_to_ZoomLink? || saved_change_to_ConversationID? || saved_change_to_MediatorID?
        "updated"
      end
    end

    if event
      actor = User.find_by(UserID: self[:MediatorID])
      previous_times = if event == "rescheduled"
        [ saved_change_to_StartTime&.first || self[:StartTime], saved_change_to_EndTime&.first || self[:EndTime] ]
      end
      notification_recipients.each do |recipient|
        MediationMailer.session_notification(recipient, self[:ConversationID], event, actor,
                                             self[:StartTime], self[:EndTime], self[:ZoomLink], previous_times).deliver_later
      end
    end

    return unless self[:Status] == "scheduled" && (event || saved_change_to_updated_at?)

    [ 24.hours, 1.hour ].each do |lead_time|
      reminder_at = self[:StartTime] - lead_time
      next unless reminder_at.future?

      MediationSessionReminderJob.set(wait_until: reminder_at).perform_later(id, reminder_version, lead_time.to_i)
    end
  end

  def end_after_start
    return if self[:StartTime].blank? || self[:EndTime].blank?

    if self[:EndTime] <= self[:StartTime]
      errors.add(:EndTime, "must be after the start time")
    end
  end

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

  def no_overlapping_meetings
    return if self[:StartTime].blank? || self[:EndTime].blank?
    return unless self[:Status] == "scheduled"

    overlapping = MediatorScheduledMeeting.where(
      MediatorID: self[:MediatorID],
      Status: "scheduled"
    ).where(
      "StartTime < ? AND EndTime > ?",
      self[:EndTime],
      self[:StartTime]
    ).where.not(id: id)

    if overlapping.exists?
      errors.add(:base, "Mediator already has a meeting during this time")
    end
  end

  def not_during_blocked_period
    return if self[:StartTime].blank? || self[:EndTime].blank?
    return if self[:MediatorID].blank?
    return unless self[:Status] == "scheduled"

    blocked = MediatorScheduleBlock.where(
      MediatorID: self[:MediatorID]
    ).where(
      "StartTime < ? AND EndTime > ?",
      self[:EndTime],
      self[:StartTime]
    ).exists?

    if blocked
      errors.add(:base, "Meeting overlaps with a blocked availability period")
    end
  end

  def within_mediator_availability
    return if self[:StartTime].blank? || self[:EndTime].blank?
    return if self[:MediatorID].blank?
    return unless self[:Status] == "scheduled"

    start_time = self[:StartTime].in_time_zone
    end_time = self[:EndTime].in_time_zone

    # For now, require meetings to start and end on the same day
    if start_time.to_date != end_time.to_date
      errors.add(:base, "Meeting must start and end on the same day")
      return
    end

    day = start_time.wday

    available = MediatorScheduleAvailability.where(
      MediatorID: self[:MediatorID],
      DayOfWeek: day
    ).any? do |slot|
      slot_start = slot[:StartTime].strftime("%H:%M:%S")
      slot_end = slot[:EndTime].strftime("%H:%M:%S")

      meeting_start = start_time.strftime("%H:%M:%S")
      meeting_end = end_time.strftime("%H:%M:%S")

      meeting_start >= slot_start && meeting_end <= slot_end
    end

    unless available
      errors.add(:base, "Meeting is outside mediator availability")
    end
  end
end


