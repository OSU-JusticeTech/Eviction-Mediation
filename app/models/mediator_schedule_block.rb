class MediatorScheduleBlock < ApplicationRecord
  belongs_to :mediator,
             foreign_key: "MediatorID",
             primary_key: "UserID"

  validates :MediatorID, presence: true
  validates :StartTime, presence: true
  validates :EndTime, presence: true

  validate :end_after_start

  private

  def end_after_start
    return if self[:StartTime].blank? || self[:EndTime].blank?

    if self[:EndTime] <= self[:StartTime]
      errors.add(:EndTime, "must be after the start time")
    end
  end
end
