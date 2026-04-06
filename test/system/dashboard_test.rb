require "application_system_test_case"

class DashboardTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @admin = users(:admin1)
    @mediator = users(:mediator1)
  end

  test "dashboard requires authentication" do
    visit dashboard_path

    assert_current_path login_path
    assert_text "You must be logged in to access the dashboard."
  end

  test "tenant can open dashboard" do
    sign_in_as(@tenant)

    assert_selector "h1", text: "Welcome back, #{@tenant.FName}!"
    assert_text "Your tenant portal for eviction mediation and resources"
    assert_link "View Messages"
  end

  test "landlord can open dashboard" do
    sign_in_as(@landlord)

    assert_selector "h1", text: "Welcome back, #{@landlord.FName}!"
    assert_text "Your landlord portal for property management and mediation"
    assert_link "View Messages"
  end

  test "admin can open dashboard" do
    sign_in_as(@admin)

    assert_selector "h1", text: "Welcome back, #{@admin.FName}!"
    assert_text "Administrative dashboard for managing mediations"
    assert_link "Manage Mediations"
  end

  test "mediator can open dashboard" do
    sign_in_as(@mediator)

    assert_selector "h1", text: "Welcome back, #{@mediator.FName}!"
    assert_text "Your mediation cases and availability center"
    assert_link "View Cases"
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