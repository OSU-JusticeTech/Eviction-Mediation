require "test_helper"

class MediatorTimeEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @mediator = users(:mediator1)
    @conversation = PrimaryMessageGroup.find_by!(MediatorID: @mediator.UserID, deleted_at: nil)
  end

  def log_in_as(user)
    post login_path, params: { email: user.Email, password: "password" }
    assert_response :redirect
  end

  def json_headers
    { "Accept" => "application/json" }
  end

  test "mediator starts tracking on their own case" do
    log_in_as(@mediator)

    assert_difference "MediatorTimeEntry.count", 1 do
      post mediator_case_time_entries_path(@conversation.ConversationID)
    end

    assert_redirected_to mediator_case_path(@conversation)
    entry = MediatorTimeEntry.last
    assert entry.active?
    assert_equal @mediator.UserID, entry.MediatorID
  end

  test "mediator cannot track a case they are not assigned to" do
    other_case = PrimaryMessageGroup.where.not(MediatorID: @mediator.UserID).first!
    log_in_as(@mediator)

    assert_no_difference "MediatorTimeEntry.count" do
      post mediator_case_time_entries_path(other_case.ConversationID)
    end

    assert_redirected_to third_party_mediations_path
  end

  test "admin cannot start tracking" do
    log_in_as(users(:admin1))

    assert_no_difference "MediatorTimeEntry.count" do
      post mediator_case_time_entries_path(@conversation.ConversationID)
    end

    assert_redirected_to dashboard_path
  end

  test "tenant cannot start tracking" do
    log_in_as(users(:tenant1))

    assert_no_difference "MediatorTimeEntry.count" do
      post mediator_case_time_entries_path(@conversation.ConversationID)
    end

    assert_redirected_to dashboard_path
  end

  test "heartbeat refreshes last activity" do
    log_in_as(@mediator)
    entry = MediatorTimeEntry.start!(@mediator.UserID, @conversation.ConversationID)
    entry.update!(LastActiveAt: 5.minutes.ago)

    patch heartbeat_time_entry_path(entry), headers: json_headers

    assert_response :no_content
    assert_in_delta Time.current.to_i, entry.reload.LastActiveAt.to_i, 5
  end

  test "heartbeat on a stopped entry returns gone" do
    log_in_as(@mediator)
    entry = MediatorTimeEntry.start!(@mediator.UserID, @conversation.ConversationID)
    entry.close!

    patch heartbeat_time_entry_path(entry), headers: json_headers

    assert_response :gone
  end

  test "another mediator cannot touch someone else's entry" do
    entry = MediatorTimeEntry.start!(@mediator.UserID, @conversation.ConversationID)
    log_in_as(users(:mediator2))

    patch stop_time_entry_path(entry), headers: json_headers

    assert_response :not_found
    assert entry.reload.active?
  end

  test "stop from the page closes the entry" do
    log_in_as(@mediator)
    entry = MediatorTimeEntry.start!(@mediator.UserID, @conversation.ConversationID)

    patch stop_time_entry_path(entry)

    assert_redirected_to mediator_case_path(@conversation.ConversationID)
    assert_not entry.reload.active?
  end

  test "idle stop credits time up to the idle limit" do
    log_in_as(@mediator)
    entry = MediatorTimeEntry.start!(@mediator.UserID, @conversation.ConversationID)
    last_active = 16.minutes.ago
    entry.update!(StartedAt: 1.hour.ago, LastActiveAt: last_active)

    patch stop_time_entry_path(entry), params: { reason: "idle" }, as: :json

    assert_response :no_content
    assert_in_delta (last_active + MediatorTimeEntry::IDLE_LIMIT).to_i, entry.reload.EndedAt.to_i, 1
  end

  test "logout stops tracking" do
    log_in_as(@mediator)
    entry = MediatorTimeEntry.start!(@mediator.UserID, @conversation.ConversationID)

    delete logout_path

    assert_not entry.reload.active?
  end
end
