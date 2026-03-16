class IntakeQuestion < ApplicationRecord
    self.table_name = "IntakeQuestions"
    self.primary_key = "IntakeID"

    belongs_to :user, foreign_key: "UserID"

    validates :Reason, inclusion: {
      in: [
        "Failure to Pay Rent",
        "Violation of Lease Terms",
        "Damage to Property",
        "Illegal Activity",
        "Nuisance or Disturbance",
        "Expiration of Lease",
        "Unknown"
      ]
    }

    validates :BestOption, inclusion: {
      in: [ "Pay Missed Rent", "Move Out" ]
    }

    validates :Section8, :TotalCostOrMonthly, inclusion: { in: [ true, false ] }
    validates :MoneyOwed,
          presence: true,
          numericality: { greater_than_or_equal_to: 0 }

    validates :PayableToday,
          presence: true,
          numericality: { greater_than_or_equal_to: 0 }

    validates :MonthlyRent,
          presence: true,
          numericality: { greater_than_or_equal_to: 0 },
          if: -> { self[:TotalCostOrMonthly] == false }

    validates :MonthlyRent,
          absence: true,
          unless: -> { self[:TotalCostOrMonthly] == false }
    has_one :primary_message_group, foreign_key: "IntakeID"
end
