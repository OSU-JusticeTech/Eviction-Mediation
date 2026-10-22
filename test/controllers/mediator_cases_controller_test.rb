require "test_helper"

class MediatorCasesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @mediator_user = users(:mediator1)
    @mediation = primary_message_groups(:one)
  end

  def log_in_as(user, expect_success: true)
    post login_path, params: { email: user[:Email], password: "password" }
    assert_redirected_to dashboard_url
    follow_redirect!
    assert_response(:success) if expect_success
  end

  test "should get show" do
    log_in_as(@mediator_user)

    get mediator_case_url(@mediation)
    assert_response :success
  end

  test "admin can view case overview in read-only mode" do
    log_in_as(users(:admin1))

    get mediator_case_url(@mediation)

    assert_response :success
    assert_select "a.back-link", text: /Back to Mediations/
    # Read-only admins do not get the mediator-only terminate action
    assert_select "form[action=?]", end_mediation_path(@mediation.ConversationID), count: 0
  end

  test "assigned mediator sees start time tracking button" do
    log_in_as(@mediator_user)

    get mediator_case_url(@mediation)

    assert_select "form[action=?]", mediator_case_time_entries_path(@mediation.ConversationID), text: /Start Time Tracking/
    assert_select ".conversation-status-pill", text: /0m logged/
  end

  test "mediator tracking this case sees stop button and navbar indicator" do
    log_in_as(@mediator_user)
    entry = MediatorTimeEntry.start!(@mediator_user.UserID, @mediation.ConversationID)

    get mediator_case_url(@mediation)

    assert_select ".page-header form[action=?]", stop_time_entry_path(entry), text: /Stop Tracking/
    assert_select "[data-time-tracker-pill]", text: /Case ##{@mediation.ConversationID}/
    assert_select "[data-controller=time-tracker]"
  end

  test "admin does not see time tracking controls" do
    log_in_as(users(:admin1))

    get mediator_case_url(@mediation)

    assert_select "form[action=?]", mediator_case_time_entries_path(@mediation.ConversationID), count: 0
  end

  test "non mediator non admin is denied case overview" do
    log_in_as(users(:tenant1))

    get mediator_case_url(@mediation)

    assert_redirected_to dashboard_path
    assert_equal "Access Denied", flash[:alert]
  end
end
