class ScreeningQuestion < ApplicationRecord
  self.table_name = "ScreeningQuestions"
  self.primary_key = "ScreeningID"

  belongs_to :user, foreign_key: "UserID"

  # Require users to fill out all required fields on screening questions
  validates :InterpreterNeeded, :DisabilityAccommodation, :ConflictOfInterest,
        :SpeakOnOwnBehalf, :NeedToConsult, :Unsafe,
        inclusion: { in: [ true, false ], message: "must be selected" }

  def soft_delete!
    update(deleted_at: Time.current)
  end

  def active?
    deleted_at.nil?
  end
end
