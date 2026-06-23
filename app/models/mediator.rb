class Mediator < ApplicationRecord
  self.table_name = "Mediators"
  self.primary_key = "UserID"

  belongs_to :user, foreign_key: "UserID"

  # Live, authoritative count of this mediator's active assigned cases. This is
  # what the cached counter should always equal; it is the source used to
  # rebuild the counter, not a hot read path (the column serves reads).
  def active_case_count
    PrimaryMessageGroup.active_for_mediator(self.UserID).count
  end

  # Rebuild the cached counter from live data. Invoked automatically whenever a
  # mediation's assignment/teardown changes (see PrimaryMessageGroup).
  def recompute_active_case_count!
    update_column(:ActiveMediations, active_case_count)
  end
end
