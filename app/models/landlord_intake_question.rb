class LandlordIntakeQuestion < ApplicationRecord
  self.table_name = "LandlordIntakeQuestions"
  self.primary_key = "LandlordIntakeID"

  belongs_to :user, foreign_key: "UserID"

  REASONS = (IntakeQuestion::REASONS - [ "Unlivable", "Unsafe", "Failure to Repair", "My Rent Will be Late" ]).freeze

  REASON_SEPARATOR = ", "

  validate :reasons_must_be_valid

  def reasons
    self[:Reason].to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def reasons=(values)
    self[:Reason] = Array(values).map { |v| v.to_s.strip }.reject(&:blank?).join(REASON_SEPARATOR)
  end

  DESIRED_OUTCOMES = [ "Receive Payment", "Have Tenant Vacate" ]

  validates :DesiredOutcome, inclusion: { in: DESIRED_OUTCOMES }, unless: :unknown_only?
  validates :AcceptPaymentPlan, inclusion: { in: [ true, false ] }, unless: :unknown_only?
  validates :AmountClaimed,
        presence: true,
        numericality: { greater_than_or_equal_to: 0 },
        unless: :unknown_only?
  validates :MonthlyRent,
        numericality: { greater_than_or_equal_to: 0 },
        allow_nil: true

  has_one :primary_message_group, foreign_key: "LandlordIntakeID"

  private

  def unknown_only?
    reasons == [ "Unknown" ]
  end

  def reasons_must_be_valid
    selected = reasons
    if selected.empty?
      errors.add(:Reason, "must include at least one reason for the dispute")
    elsif (selected - REASONS).any?
      errors.add(:Reason, "contains an invalid selection")
    end
  end
end
