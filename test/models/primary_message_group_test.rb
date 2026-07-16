require "test_helper"

class PrimaryMessageGroupTest < ActiveSupport::TestCase
  test "uses the correct table name and primary key" do
    assert_equal "PrimaryMessageGroups", PrimaryMessageGroup.table_name
    assert_equal "ConversationID", PrimaryMessageGroup.primary_key
  end

  test "validations require ConversationID, TenantID, LandlordID" do
    pmg = PrimaryMessageGroup.new
    assert_not pmg.valid?
    assert_includes pmg.errors.attribute_names.map(&:to_s), "ConversationID"
    assert_includes pmg.errors.attribute_names.map(&:to_s), "TenantID"
    assert_includes pmg.errors.attribute_names.map(&:to_s), "LandlordID"
  end

  # --- Status classification ---------------------------------------

  test "pending and awaiting landlord acceptance when nothing accepted" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: false, accepted_by_tenant: false, IntakeID: nil, deleted_at: nil)

    assert_equal :pending, pmg.status_category
    assert_equal :awaiting_landlord_acceptance, pmg.pending_stage
    assert pmg.pending?
    assert_not pmg.active?
    assert_not pmg.past?
  end

  test "awaiting tenant acceptance when only the landlord has accepted" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: false, IntakeID: nil, deleted_at: nil)

    assert_equal :pending, pmg.status_category
    assert_equal :awaiting_tenant_acceptance, pmg.pending_stage
  end

  test "awaiting intake when both accepted but no intakes on file" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: nil, LandlordIntakeID: nil, deleted_at: nil)

    assert_equal :pending, pmg.status_category
    assert_equal :awaiting_intake, pmg.pending_stage
    assert pmg.needs_tenant_intake?
    assert pmg.needs_landlord_intake?
  end

  test "awaiting intake when only tenant intake is complete" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, LandlordIntakeID: nil, deleted_at: nil)

    assert_equal :pending, pmg.status_category
    assert_equal :awaiting_intake, pmg.pending_stage
    assert_not pmg.needs_tenant_intake?
    assert pmg.needs_landlord_intake?
  end

  test "awaiting intake when only landlord intake is complete" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: nil, LandlordIntakeID: 1, deleted_at: nil)

    assert_equal :pending, pmg.status_category
    assert_equal :awaiting_intake, pmg.pending_stage
    assert pmg.needs_tenant_intake?
    assert_not pmg.needs_landlord_intake?
  end

  test "active once both parties accepted and both intakes are complete" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, LandlordIntakeID: 1, deleted_at: nil)

    assert_equal :active, pmg.status_category
    assert pmg.active?
    assert_nil pmg.pending_stage
  end

  test "past once ended regardless of other flags" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, LandlordIntakeID: 1, deleted_at: Time.current)

    assert_equal :past, pmg.status_category
    assert pmg.past?
    assert_not pmg.active?
    assert_nil pmg.pending_stage
  end

  # --- Needs-action (default board grouping) -----------------------

  test "landlord needs to act while awaiting landlord acceptance" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: false, accepted_by_tenant: false, IntakeID: nil, deleted_at: nil)

    assert pmg.needs_action_from?("Landlord")
    assert_not pmg.needs_action_from?("Tenant")
  end

  test "tenant needs to act while awaiting tenant acceptance" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: false, IntakeID: nil, deleted_at: nil)

    assert pmg.needs_action_from?("Tenant")
    assert_not pmg.needs_action_from?("Landlord")
  end

  test "tenant needs to act while their intake is missing" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: nil, LandlordIntakeID: nil, deleted_at: nil)

    assert pmg.needs_action_from?("Tenant")
    assert pmg.needs_action_from?("Landlord")
  end

  test "landlord needs to act when only their intake is missing" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, LandlordIntakeID: nil, deleted_at: nil)

    assert_not pmg.needs_action_from?("Tenant")
    assert pmg.needs_action_from?("Landlord")
  end

  test "tenant needs to act when only their intake is missing" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: nil, LandlordIntakeID: 1, deleted_at: nil)

    assert pmg.needs_action_from?("Tenant")
    assert_not pmg.needs_action_from?("Landlord")
  end

  test "no one needs to act on active or past mediations" do
    pmg = primary_message_groups(:one)

    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, LandlordIntakeID: 1, deleted_at: nil)
    assert_not pmg.needs_action_from?("Tenant")
    assert_not pmg.needs_action_from?("Landlord")

    pmg.assign_attributes(deleted_at: Time.current)
    assert_not pmg.needs_action_from?("Tenant")
    assert_not pmg.needs_action_from?("Landlord")
  end

  # --- pending_action_for (tiered board ordering) ------------------

  test "pending request awaiting the viewer is a respond action" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: false, accepted_by_tenant: false, IntakeID: nil, deleted_at: nil)

    assert_equal :respond, pmg.pending_action_for("Landlord", feedback_pending: false)
    assert_nil pmg.pending_action_for("Tenant", feedback_pending: false)
  end

  test "ended mediation still owing feedback is a feedback action" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, LandlordIntakeID: 1, deleted_at: Time.current)

    assert_equal :feedback, pmg.pending_action_for("Tenant", feedback_pending: true)
    assert_equal :feedback, pmg.pending_action_for("Landlord", feedback_pending: true)
  end

  test "ended mediation with feedback submitted needs no action" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, LandlordIntakeID: 1, deleted_at: Time.current)

    assert_nil pmg.pending_action_for("Tenant", feedback_pending: false)
    assert_nil pmg.pending_action_for("Landlord", feedback_pending: false)
  end

  test "respond takes precedence and active mediations need no action" do
    pmg = primary_message_groups(:one)

    # A live pending request is a respond action regardless of feedback state.
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: false, IntakeID: nil, LandlordIntakeID: nil, deleted_at: nil)
    assert_equal :respond, pmg.pending_action_for("Tenant", feedback_pending: true)

    # An active mediation has nothing outstanding.
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, LandlordIntakeID: 1, deleted_at: nil)
    assert_nil pmg.pending_action_for("Tenant", feedback_pending: true)
  end

  # --- Outcome -----------------------------------------------------

  test "Outcome rejects values outside the defined set" do
    pmg = primary_message_groups(:one)
    pmg.Outcome = "Something else"

    assert_not pmg.valid?
    assert_includes pmg.errors.attribute_names.map(&:to_s), "Outcome"
  end

  test "Outcome accepts the three defined outcomes and nil" do
    pmg = primary_message_groups(:one)

    pmg.Outcome = nil
    assert pmg.valid?

    PrimaryMessageGroup::OUTCOMES.each do |outcome|
      pmg.Outcome = outcome
      assert pmg.valid?, "expected #{outcome.inspect} to be a valid outcome"
    end
  end

  test "outcome is not editable while the mediation is still active" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(deleted_at: nil, MediatorAssigned: false, MediatorID: nil, requested_by: "Tenant")

    assert_not pmg.outcome_editable_by?(users(:tenant1))
  end

  test "only the assigned mediator can edit the outcome when a mediator is assigned" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(deleted_at: Time.current, MediatorAssigned: true,
                          MediatorID: users(:mediator1).UserID, requested_by: "Tenant")

    assert pmg.outcome_editable_by?(users(:mediator1))
    assert_not pmg.outcome_editable_by?(users(:tenant1))
    assert_not pmg.outcome_editable_by?(users(:landlord1))
  end

  test "only the requester can edit the outcome when no mediator is assigned" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(deleted_at: Time.current, MediatorAssigned: false,
                          MediatorID: nil, requested_by: "Landlord")

    assert pmg.outcome_editable_by?(users(:landlord1))
    assert_not pmg.outcome_editable_by?(users(:tenant1))
    assert_not pmg.outcome_editable_by?(users(:mediator1))
  end

  test "outcome_editable_by? is false for a nil user" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(deleted_at: Time.current, MediatorAssigned: false,
                          MediatorID: nil, requested_by: "Tenant")

    assert_not pmg.outcome_editable_by?(nil)
  end

  # --- Closing permission ------------------------------------------

  test "only the requester can close when no mediator is assigned" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(deleted_at: nil, MediatorAssigned: false,
                          MediatorID: nil, requested_by: "Tenant")

    assert pmg.closable_by?(users(:tenant1))
    assert_not pmg.closable_by?(users(:landlord1))
    assert_not pmg.closable_by?(users(:mediator1))
  end

  test "the requester and the assigned mediator can close when a mediator is assigned" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(deleted_at: nil, MediatorAssigned: true,
                          MediatorID: users(:mediator1).UserID, requested_by: "Landlord")

    assert pmg.closable_by?(users(:landlord1))
    assert pmg.closable_by?(users(:mediator1))
    assert_not pmg.closable_by?(users(:tenant1))
  end

  test "closable_by? is false once the mediation has ended" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(deleted_at: Time.current, MediatorAssigned: false,
                          MediatorID: nil, requested_by: "Tenant")

    assert_not pmg.closable_by?(users(:tenant1))
  end

  test "closable_by? is false for a nil user" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(deleted_at: nil, MediatorAssigned: false,
                          MediatorID: nil, requested_by: "Tenant")

    assert_not pmg.closable_by?(nil)
  end
end
