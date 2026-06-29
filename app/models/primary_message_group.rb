class PrimaryMessageGroup < ApplicationRecord
  self.table_name = "PrimaryMessageGroups"
  self.primary_key = "ConversationID"
  validates :ConversationID, :TenantID, :LandlordID, presence: true
  validates :accepted_by_landlord, inclusion: { in: [ true, false ] }
  validates :accepted_by_tenant, inclusion: { in: [ true, false ] }
  belongs_to :intake_question, foreign_key: "IntakeID", optional: true
  belongs_to :landlord_intake_question, foreign_key: "LandlordIntakeID", optional: true
  belongs_to :tenant, class_name: "User", foreign_key: "TenantID"
  belongs_to :landlord, class_name: "User", foreign_key: "LandlordID"
  belongs_to :mediator, class_name: "User", foreign_key: "MediatorID", optional: true
  belongs_to :linked_message_string, foreign_key: "ConversationID", primary_key: "ConversationID", class_name: "MessageString", optional: true

  # Mediations currently assigned to the given mediator and not yet ended.
  # This is the authoritative definition of a mediator's active caseload; the
  # denormalized Mediator#ActiveMediations counter is re-derived from it below.
  scope :active_for_mediator, ->(user_id) {
    where(MediatorID: user_id, MediatorAssigned: true, deleted_at: nil)
  }

  # ------------------------------------------------------------------
  # Mediator caseload counter cache
  #
  # Mediator#ActiveMediations is a denormalized count that the admin capacity
  # query relies on to filter and sort every mediator by load in a single SQL
  # statement. To keep that counter trustworthy, any change to the columns that
  # define an "active assigned case" re-derives the affected mediators' counts
  # from the live scope above. Recomputing (rather than +/-1 bookkeeping in each
  # controller) means the counter cannot drift, regardless of which code path
  # made the change — controller, console, seeds, or a future caller.
  # ------------------------------------------------------------------
  after_save :sync_mediator_caseload, if: :caseload_columns_changed?

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
    # `self.` is required: bare column names would be parsed as constants.
    !past? && accepted_by_landlord? && accepted_by_tenant? && self.IntakeID.present? && self.LandlordIntakeID.present?
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

    :awaiting_intake
  end

  def needs_tenant_intake?
    !past? && accepted_by_tenant? && self.IntakeID.blank?
  end

  def needs_landlord_intake?
    !past? && accepted_by_landlord? && accepted_by_tenant? && self.LandlordIntakeID.blank?
  end

  # Timestamp used to order mediations within a group (most recent first).
  # Past mediations sort by when they ended; everything else by creation.
  def last_activity_at
    deleted_at || self.CreatedAt || Time.at(0)
  end

  # Whether the given viewer (a "Tenant" or "Landlord") is the party who must
  # respond next on this pending mediation (accept/reject or complete intake).
  # The same pending record reads as "needs action" to whoever must respond and
  # as "waiting" to the other party.
  def needs_action_from?(viewer_role)
    case viewer_role
    when "Tenant"
      pending_stage == :awaiting_tenant_acceptance || needs_tenant_intake?
    when "Landlord"
      pending_stage == :awaiting_landlord_acceptance || needs_landlord_intake?
    else
      false
    end
  end

  # The action (if any) the given viewer must take, used to build the default
  # "Needs Action" board grouping and ordering. `feedback_pending` says whether
  # the viewer still owes a good-faith feedback survey; the caller supplies it
  # so this method stays query-free.
  #
  #   :respond  - a pending request awaiting this viewer (accept/reject/intake)
  #   :feedback - an ended mediation still awaiting this viewer's feedback
  #   nil       - nothing for this viewer to do
  def pending_action_for(viewer_role, feedback_pending:)
    return :respond if needs_action_from?(viewer_role)
    return :feedback if past? && feedback_pending

    nil
  end

  private

  # Did this save touch a column that determines whether the mediation counts
  # toward a mediator's active caseload?
  def caseload_columns_changed?
    saved_change_to_MediatorAssigned? ||
      saved_change_to_deleted_at? ||
      saved_change_to_MediatorID?
  end

  # Re-derive ActiveMediations for every mediator this save could have affected.
  # On a reassignment that includes the previous mediator, so the case they lost
  # is subtracted as well as added to the new one.
  def sync_mediator_caseload
    affected_ids = [ self.MediatorID ]
    affected_ids << self.MediatorID_before_last_save if saved_change_to_MediatorID?

    Mediator.where(UserID: affected_ids.compact.uniq).find_each(&:recompute_active_case_count!)
  end
end
