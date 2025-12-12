class Mediator < ApplicationRecord
  self.table_name = "Mediators"
  self.primary_key = "UserID"

  belongs_to :user, foreign_key: "UserID"
end
