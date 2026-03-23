require "test_helper"

class Admin::FlaggedMediationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin1)
    @tenant = users(:tenant1)
    @new_mediator = users(:mediator2)

    # Setup unassigned mediation
    @unassigned = primary_message_groups(:one)
    @unassigned.update!(MediatorRequested: true, MediatorAssigned: false, MediatorID: nil)

    # Setup completed mediation
    @completed = primary_message_groups(:two)
    @completed.update!(deleted_at: Time.current)

    post login_url, params: { email: @admin[:Email], password: "password" }
    assert_redirected_to dashboard_url
    follow_redirect!
    assert_response :success
  end

  test "lists unassigned and completed mediations for admins" do
    get admin_mediations_url

    assert_response :success
    assert_select "h1", "Mediations Dashboard"

    # Check for Unassigned section
    assert_select "h2", "Unassigned Mediator Requests"
    assert_select "td", text: /#{@unassigned.tenant.FName}/

    # Check for Completed section
    assert_select "h2", "Completed Mediations"
    assert_select "td", text: /#{@completed.tenant.FName}/
  end

  test "shows a specific mediation" do
    get admin_flagged_mediation_url(@unassigned)

    assert_response :success
    assert_select "h1", "Mediation Details"
    assert_select ".card-header h2", text: /Tenant|Landlord/
  end

  test "non admin is redirected from admin mediations" do
    delete logout_path
    post login_url, params: { email: @tenant[:Email], password: "password" }

    get admin_mediations_url

    assert_redirected_to dashboard_path
    assert_equal "Access Denied", flash[:alert]
  end

  test "reassign requires mediator id" do
    patch admin_reassign_mediator_url(@unassigned), params: { new_mediator_id: "" }

    assert_redirected_to admin_flagged_mediation_path(@unassigned)
    assert_equal "No mediator selected.", flash[:alert]
  end

  test "initial mediator assignment creates side conversations" do
    assert_difference("SideMessageGroup.count", 2) do
      patch admin_reassign_mediator_url(@unassigned), params: { new_mediator_id: @new_mediator.UserID }
    end

    assert_redirected_to admin_mediations_path
    @unassigned.reload
    assert_equal @new_mediator.UserID, @unassigned.MediatorID
    assert_equal true, @unassigned.MediatorAssigned
    assert_not_nil @unassigned.TenantSideConversationID
    assert_not_nil @unassigned.LandlordSideConversationID
  end

  test "reassignment soft deletes screenings and clears links" do
    original_mediator_id = users(:mediator1).UserID
    @unassigned.update!(
      MediatorAssigned: true,
      MediatorRequested: true,
      MediatorID: original_mediator_id,
      TenantScreeningID: screening_questions(:one).ScreeningID,
      LandlordScreeningID: screening_questions(:two).ScreeningID
    )

    patch admin_reassign_mediator_url(@unassigned), params: { new_mediator_id: @new_mediator.UserID }

    assert_redirected_to admin_mediations_path
    @unassigned.reload
    assert_equal @new_mediator.UserID, @unassigned.MediatorID
    assert_nil @unassigned.TenantScreeningID
    assert_nil @unassigned.LandlordScreeningID
    assert_not_nil screening_questions(:one).reload.deleted_at
    assert_not_nil screening_questions(:two).reload.deleted_at
  end

  test "reassign rejects assigning same mediator" do
    current_mediator_id = users(:mediator1).UserID
    @unassigned.update!(MediatorAssigned: true, MediatorID: current_mediator_id)

    patch admin_reassign_mediator_url(@unassigned), params: { new_mediator_id: current_mediator_id }

    assert_redirected_to admin_flagged_mediation_path(@unassigned)
    assert_equal "New mediator must be different from the current one.", flash[:alert]
  end

  test "initial assignment increments mediator load" do
    mediator_record = mediators(:mediator2)

    patch admin_reassign_mediator_url(@unassigned), params: { new_mediator_id: @new_mediator.UserID }

    assert_redirected_to admin_mediations_path
    assert_equal 2, mediator_record.reload.ActiveMediations
  end

  test "reassignment decrements old mediator and increments new mediator" do
    old_mediator = mediators(:mediator1)
    new_mediator = mediators(:mediator2)
    @unassigned.update!(
      MediatorAssigned: true,
      MediatorRequested: true,
      MediatorID: old_mediator.UserID,
      TenantScreeningID: screening_questions(:one).ScreeningID,
      LandlordScreeningID: screening_questions(:two).ScreeningID
    )

    patch admin_reassign_mediator_url(@unassigned), params: { new_mediator_id: new_mediator.UserID }

    assert_redirected_to admin_mediations_path
    assert_equal 2, old_mediator.reload.ActiveMediations
    assert_equal 2, new_mediator.reload.ActiveMediations
  end
end
