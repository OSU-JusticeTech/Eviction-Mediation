class PrimaryMessageGroup < ApplicationRecord
  self.table_name = "PrimaryMessageGroups"
  self.primary_key = "ConversationID"
  validates :ConversationID, :TenantID, :LandlordID, presence: true
  validates :accepted_by_landlord, inclusion: { in: [ true, false ] }
  validates :accepted_by_tenant, inclusion: { in: [ true, false ] }
  belongs_to :intake_question, foreign_key: "IntakeID", optional: true
  belongs_to :tenant, class_name: "User", foreign_key: "TenantID"
  belongs_to :landlord, class_name: "User", foreign_key: "LandlordID"
  belongs_to :mediator, class_name: "User", foreign_key: "MediatorID", optional: true
  belongs_to :linked_message_string, foreign_key: "ConversationID", primary_key: "ConversationID", class_name: "MessageString", optional: true

  # ------------------------------------------------------------------
  # Status classification
  #
  # Every mediation belongs to exactly one of three coarse stages that
  # drive how it is grouped, sorted, and filtered on the messages page:
  #
  #   :active  -> both parties accepted and the tenant finished intake
  #   :pending -> a request exists but is still waiting on someone
  #   :past    -> the mediation has been ended (soft deleted)
  #
  # Keeping this logic on the model lets a controller load every
  # mediation into a single list and ask each record where it belongs,
  # rather than running a separate query per status.
  # ------------------------------------------------------------------

  def past?
    deleted_at.present?
  end

  def active?
    # `self.` is required: a bare `IntakeID` would be parsed as a constant.
    !past? && accepted_by_landlord? && accepted_by_tenant? && self.IntakeID.present?
  end

  def pending?
    !past? && !active?
  end

  # Coarse bucket used for grouping/sorting/filtering.
  def status_category
    return :past if past?
    return :active if active?

    :pending
  end

  # Finer-grained breakdown of a pending mediation. Returns nil for any
  # mediation that is not pending.
  def pending_stage
    return nil unless pending?
    return :awaiting_landlord_acceptance unless accepted_by_landlord?
    return :awaiting_tenant_acceptance unless accepted_by_tenant?

    :awaiting_tenant_intake
  end

  # Timestamp used to order mediations within a group (most recent first).
  # Past mediations sort by when they ended; everything else by creation.
  def last_activity_at
    deleted_at || self.CreatedAt || Time.at(0)
  end
end
