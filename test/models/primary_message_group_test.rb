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

  test "awaiting tenant intake when both accepted but no intake on file" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: nil, deleted_at: nil)

    assert_equal :pending, pmg.status_category
    assert_equal :awaiting_tenant_intake, pmg.pending_stage
  end

  test "active once both parties accepted and intake is complete" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, deleted_at: nil)

    assert_equal :active, pmg.status_category
    assert pmg.active?
    assert_nil pmg.pending_stage
  end

  test "past once ended regardless of other flags" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, deleted_at: Time.current)

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

  test "tenant needs to act while awaiting tenant intake" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: nil, deleted_at: nil)

    assert pmg.needs_action_from?("Tenant")
    assert_not pmg.needs_action_from?("Landlord")
  end

  test "no one needs to act on active or past mediations" do
    pmg = primary_message_groups(:one)

    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, deleted_at: nil)
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
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, deleted_at: Time.current)

    assert_equal :feedback, pmg.pending_action_for("Tenant", feedback_pending: true)
    assert_equal :feedback, pmg.pending_action_for("Landlord", feedback_pending: true)
  end

  test "ended mediation with feedback submitted needs no action" do
    pmg = primary_message_groups(:one)
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, deleted_at: Time.current)

    assert_nil pmg.pending_action_for("Tenant", feedback_pending: false)
    assert_nil pmg.pending_action_for("Landlord", feedback_pending: false)
  end

  test "respond takes precedence and active mediations need no action" do
    pmg = primary_message_groups(:one)

    # A live pending request is a respond action regardless of feedback state.
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: false, IntakeID: nil, deleted_at: nil)
    assert_equal :respond, pmg.pending_action_for("Tenant", feedback_pending: true)

    # An active mediation has nothing outstanding.
    pmg.assign_attributes(accepted_by_landlord: true, accepted_by_tenant: true, IntakeID: 1, deleted_at: nil)
    assert_nil pmg.pending_action_for("Tenant", feedback_pending: true)
  end
end
