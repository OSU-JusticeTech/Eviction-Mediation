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

  private

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


