class IntakeQuestion < ApplicationRecord
    self.table_name = "IntakeQuestions"
    self.primary_key = "IntakeID"

    belongs_to :user, foreign_key: "UserID"

    REASONS = [
      "Failure to Pay Rent",
      "Violation of Lease Terms",
      "Damage to Property",
      "Illegal Activity",
      "Nuisance or Disturbance",
      "Expiration of Lease",
      "Unlivable",
      "Unsafe",
      "Failure to Repair",
      "My Rent Will be Late",
      "Unknown"
    ]

    # Multiple reasons are stored as a comma-separated string in the Reason column.
    REASON_SEPARATOR = ", "

    validate :reasons_must_be_valid

    # Returns the selected reasons as an array.
    def reasons
      self[:Reason].to_s.split(",").map(&:strip).reject(&:blank?)
    end

    # Accepts an array (or single value) of reasons and stores them joined.
    def reasons=(values)
      self[:Reason] = Array(values).map { |v| v.to_s.strip }.reject(&:blank?).join(REASON_SEPARATOR)
    end

    validates :BestOption, inclusion: { in: [ "Pay Missed Rent", "Move Out" ] }, unless: :unknown_only?
    validates :Section8, :TotalCostOrMonthly, inclusion: { in: [ true, false ] }, unless: :unknown_only?
    validates :MoneyOwed,
          presence: true,
          numericality: { greater_than_or_equal_to: 0 },
          unless: :unknown_only?

    validates :PayableToday,
          presence: true,
          numericality: { greater_than_or_equal_to: 0 },
          unless: :unknown_only?

    validates :MonthlyRent,
          presence: true,
          numericality: { greater_than_or_equal_to: 0 },
          if: -> { !unknown_only? && self[:TotalCostOrMonthly] == false }

    validates :MonthlyRent,
          absence: true,
          unless: -> { unknown_only? || self[:TotalCostOrMonthly] == false }
    has_one :primary_message_group, foreign_key: "IntakeID"

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
