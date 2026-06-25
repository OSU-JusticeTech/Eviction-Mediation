require "application_system_test_case"

class AdminMediatorProfileTest < ApplicationSystemTestCase
  setup do
    @admin = users(:admin1)
    @mediator_user = users(:mediator1)
    @mediator = mediators(:mediator1)
    @mediation = primary_message_groups(:one)

    @mediation.update!(
      MediatorAssigned: true,
      MediatorID: @mediator_user.UserID,
      deleted_at: nil
    )
  end

  test "admin can navigate to mediator profile from dashboard" do
    sign_in_as(@admin)
    visit dashboard_path

    click_link "#{@mediator_user.FName} #{@mediator_user.LName}"

    assert_current_path admin_account_path(@mediator_user)
    assert_selector "h1", text: "#{@mediator_user.FName} #{@mediator_user.LName}"
  end

  test "mediator profile shows correct identity and status" do
    sign_in_as(@admin)
    visit admin_account_path(@mediator_user)

    assert_text @mediator_user.Email
    assert_text @mediator.Available ? /available/i : /busy/i
    assert_text @mediator.MediationCap.to_s
    assert_text @mediator.ActiveMediations.to_s
  end

  test "mediator profile lists active mediations with view links" do
    sign_in_as(@admin)
    visit admin_account_path(@mediator_user)

    assert_text "Case ##{@mediation.ConversationID}"
    assert_link "View Case", href: mediator_case_path(@mediation)
  end

  test "admin can update mediation cap inline and stay on profile page" do
    sign_in_as(@admin)
    visit admin_account_path(@mediator_user)

    fill_in "mediation_cap", with: 8
    click_button "Update"

    assert_current_path admin_account_path(@mediator_user)
    assert_text "Mediation cap updated successfully."
    assert_equal 8, @mediator.reload.MediationCap
  end

  test "back link from mediator profile returns to referring page" do
    sign_in_as(@admin)
    visit admin_accounts_path
    click_link "View Profile", href: admin_account_path(@mediator_user)

    assert_current_path admin_account_path(@mediator_user)

    click_link "Back"

    assert_current_path admin_accounts_path
  end

  test "mediator profile shows empty state when mediator has no active cases" do
    @mediation.update!(MediatorAssigned: false)
    sign_in_as(@admin)
    visit admin_account_path(@mediator_user)

    assert_text "No active mediations currently assigned."
  end

  test "admin can reach mediator profile from accounts page mediator list" do
    sign_in_as(@admin)
    visit admin_accounts_path

    assert_text "#{@mediator_user.FName} #{@mediator_user.LName}"
    click_link "View Profile", href: admin_account_path(@mediator_user)

    assert_current_path admin_account_path(@mediator_user)
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
