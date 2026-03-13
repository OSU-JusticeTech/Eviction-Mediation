require "application_system_test_case"

class MediationsDecisionTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @other_landlord = users(:landlord2)
    @mediation = primary_message_groups(:one)
    @message_string = message_strings(:one)
  end

  test "landlord can accept a pending negotiation" do
    @mediation.update!(accepted_by_landlord: false, accepted_by_tenant: true, deleted_at: nil)
    @message_string.update!(deleted_at: nil)

    sign_in_as(@landlord)
    visit messages_path
    dismiss_terms_modal_if_present

    click_button "Accept"

    assert_current_path messages_path
    assert_text "Negotiation accepted. You can now view and respond to the negotiation."
    assert @mediation.reload.accepted_by_landlord
  end

  test "tenant can accept a pending negotiation" do
    @mediation.update!(accepted_by_landlord: true, accepted_by_tenant: false, IntakeID: nil, deleted_at: nil)
    @message_string.update!(deleted_at: nil)

    sign_in_as(@tenant)
    visit messages_path
    dismiss_terms_modal_if_present

    click_button "Accept Negotiation"

    assert_current_path messages_path
    assert_text "Negotiation accepted. You can now view and respond to the negotiation."
    assert @mediation.reload.accepted_by_tenant
  end

  test "tenant can reject a pending negotiation" do
    @mediation.update!(accepted_by_landlord: true, accepted_by_tenant: false, IntakeID: nil, deleted_at: nil)
    @message_string.update!(deleted_at: nil)

    sign_in_as(@tenant)
    visit messages_path
    dismiss_terms_modal_if_present

    click_button "Reject Request"

    assert_current_path messages_path
    assert_text "Negotiation request rejected."
    assert_not_nil @mediation.reload.deleted_at
    assert_not_nil @message_string.reload.deleted_at
  end

  private

  def sign_in_as(user)
    visit login_path
    fill_in "email", with: user.Email
    fill_in "password", with: "password"
    click_button "Log In"
    dismiss_terms_modal_if_present
  end

  def dismiss_terms_modal_if_present
    return unless page.has_button?("OK", wait: 1)

    click_button "OK"
  end
end