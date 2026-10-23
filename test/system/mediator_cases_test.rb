require "application_system_test_case"

class MediatorCasesTest < ApplicationSystemTestCase
  setup do
    @mediator = users(:mediator1)
    @other_mediator = users(:mediator2)
    @tenant = users(:tenant1)
    @assigned_case = primary_message_groups(:one)
  end

  test "mediator can view assigned case details" do
    sign_in_as(@mediator)
    visit mediator_case_path(@assigned_case)

    assert_selector "h1", text: "Mediation Case Details"
    assert_text @tenant.Email
    assert_link "Open Chat"
  end

  test "mediator cannot view case not assigned to them" do
    sign_in_as(@other_mediator)
    visit mediator_case_path(@assigned_case)

    assert_current_path third_party_mediations_path
    assert_text "You are no longer assigned to this mediation."
  end

  test "mediator starts and stops time tracking" do
    sign_in_as(@mediator)
    visit mediator_case_path(@assigned_case)

    click_button "Start Time Tracking"

    assert_text "Time tracking started."
    assert_selector "[data-time-tracker-pill]", text: "Case ##{@assigned_case.ConversationID}"

    # The indicator follows the mediator around the site.
    visit third_party_mediations_path
    assert_selector "[data-time-tracker-pill]"

    visit mediator_case_path(@assigned_case)
    click_button "Stop Tracking"

    assert_text "Time tracking stopped."
    assert_no_selector "[data-time-tracker-pill]"
    assert_button "Start Time Tracking"
    assert_not MediatorTimeEntry.where(MediatorID: @mediator.UserID).active.exists?
  end

  test "confirming the idle prompt keeps tracking" do
    start_tracking_and_go_idle

    assert_selector "[data-time-tracker-target=modal]", text: "Are you still there?"
    click_button "I'm still here"

    assert_no_selector "[data-time-tracker-target=modal]"
    assert_selector "[data-time-tracker-pill]"
    assert MediatorTimeEntry.where(MediatorID: @mediator.UserID).active.exists?
  end

  test "ignoring the idle prompt stops tracking" do
    start_tracking_and_go_idle

    assert_selector "[data-time-tracker-target=modal]", text: "Are you still there?"

    assert_text "Time tracking stopped due to inactivity.", wait: 5
    assert_no_selector "[data-time-tracker-pill]"
    assert_not MediatorTimeEntry.where(MediatorID: @mediator.UserID).active.exists?
  end

  private

  # Shortens the idle/confirm windows and backdates the last activity so the
  # "still there?" prompt opens immediately.
  def start_tracking_and_go_idle
    sign_in_as(@mediator)
    visit mediator_case_path(@assigned_case)
    click_button "Start Time Tracking"
    assert_selector "[data-time-tracker-pill]"

    page.execute_script(<<~JS)
      const tracker = document.querySelector("[data-controller=time-tracker]")
      tracker.dataset.timeTrackerIdleMsValue = "1000"
      tracker.dataset.timeTrackerConfirmMsValue = "2000"
      const id = tracker.dataset.timeTrackerEntryIdValue
      localStorage.setItem(`timeTracker:lastActivity:${id}`, String(Date.now() - 5000))
    JS
  end

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