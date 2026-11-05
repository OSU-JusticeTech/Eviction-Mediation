require "test_helper"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediation = primary_message_groups(:one)
    @token = SecureRandom.uuid
    @notification = create_notification(@tenant, "Your notification")
    @other_notification = create_notification(@landlord, "Other user's notification")
  end

  test "all endpoints require login" do
    get notifications_path
    assert_redirected_to login_path
    get menu_notifications_path
    assert_redirected_to login_path
    patch notification_path(@notification)
    assert_redirected_to login_path
    patch open_notification_path(@notification)
    assert_redirected_to login_path
    patch mark_all_read_notifications_path
    assert_redirected_to login_path
    assert @notification.reload.unread?
  end

  test "history and dropdown show only the signed in user's notifications" do
    log_in_as(@tenant)
    [ notifications_path, menu_notifications_path ].each do |path|
      get path
      assert_response :success
      assert_includes response.body, "Your notification"
      assert_not_includes response.body, "Other user&#39;s notification"
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_select "turbo-frame#notification_menu"
      assert_select ".notification-badge", text: "1"
    end
    assert @notification.reload.unread?
  end

  test "users cannot read or open someone else's notification" do
    log_in_as(@tenant)
    patch notification_path(@other_notification)
    assert_response :not_found
    patch open_notification_path(@other_notification)
    assert_response :not_found
    assert @other_notification.reload.unread?
  end

  test "bell renders immediately without a duplicate request or self-referencing response" do
    log_in_as(@tenant)
    get notifications_path
    assert_select "turbo-frame#notification_menu[data-notifications-menu-url-value=?]", menu_notifications_path do
      assert_select ".notification-bell", count: 1
    end
    assert_select "turbo-frame#notification_menu[src]", count: 0

    get menu_notifications_path, headers: { "Turbo-Frame" => "notification_menu" }
    assert_response :success
    assert_select "turbo-frame#notification_menu" do
      assert_select ".notification-bell", count: 1
    end
    assert_select "turbo-frame#notification_menu[src]", count: 0
  end

  test "opening a notification marks it read and redirects to its target" do
    log_in_as(@tenant)
    patch open_notification_path(@notification)
    assert_response :see_other
    assert_redirected_to @notification.action_path
    assert_not @notification.reload.unread?
    get menu_notifications_path
    assert_select ".notification-badge", count: 0
  end

  test "mark as read leaves other users' notifications untouched" do
    log_in_as(@tenant)
    patch notification_path(@notification)
    assert_redirected_to notifications_path
    assert_not @notification.reload.unread?
    read_at = @notification.read_at
    travel 1.hour do
      patch notification_path(@notification)
      assert_equal read_at, @notification.reload.read_at
    end
    assert @other_notification.reload.unread?
  end

  test "mark all as read affects only the signed in user" do
    second = create_notification(@tenant, "Another notification")
    log_in_as(@tenant)
    patch mark_all_read_notifications_path
    assert_redirected_to notifications_path
    assert_not @notification.reload.unread?
    assert_not second.reload.unread?
    assert @other_notification.reload.unread?
  end

  test "unread filter excludes read notifications and renders an empty state after reading" do
    @notification.mark_as_read!
    log_in_as(@tenant)
    get notifications_path(filter: "unread")
    assert_response :success
    assert_select ".notification-card", count: 0
    assert_select ".notifications-empty h2", text: "You're all caught up"
  end

  test "history is paginated newest first and dropdown is limited to five" do
    21.times { |i| create_notification(@tenant, "Notification #{i}") }
    log_in_as(@tenant)
    get notifications_path
    assert_select ".notification-list > li", count: 20
    assert_select ".notification-list > li:first-child h2", text: "Notification 20"
    get notifications_path(page: 2)
    assert_select ".notification-list > li", count: 2
    get menu_notifications_path
    assert_select ".notification-preview", count: 5
  end

  test "notification text is escaped" do
    @notification.update!(title: '<script>alert("title")</script>', body: '<img src=x onerror="alert(1)">')
    log_in_as(@tenant)
    get notifications_path
    assert_select ".notification-card script", count: 0
    assert_select ".notification-body img", count: 0
    assert_includes response.body, "&lt;script&gt;"
  end

  test "the notification bell is present for every role" do
    [ @tenant, @landlord, users(:mediator1), users(:admin1) ].each do |user|
      log_in_as(user)
      get notifications_path
      assert_response :success
      assert_select ".navbar-right .notification-bell", count: 1
    end
  end

  test "presence requires login and a valid token" do
    patch presence_notifications_path, params: { token: @token, conversation_id: @mediation.id }
    assert_redirected_to login_path
    log_in_as(@tenant)
    patch presence_notifications_path, params: { token: "invalid", conversation_id: @mediation.id }
    assert_response :bad_request
  end

  test "heartbeat registers and renews only the authenticated user's presence" do
    log_in_as(@tenant)
    2.times do
      patch presence_notifications_path, params: { token: @token, conversation_id: @mediation.id }
      assert_response :no_content
    end
    assert_equal 1, @tenant.chat_presences.count
    assert ChatPresence.viewing?(@tenant.UserID, @mediation.id)
    assert_not ChatPresence.viewing?(@mediation.LandlordID, @mediation.id)
    travel 31.seconds do
      assert_not ChatPresence.viewing?(@tenant.UserID, @mediation.id)
    end
  end

  test "unrelated users cannot register presence in the conversation" do
    log_in_as(users(:tenant2))
    assert_no_difference "ChatPresence.count" do
      patch presence_notifications_path, params: { token: @token, conversation_id: @mediation.id }
    end
    assert_response :forbidden
  end

  test "leaving one tab does not clear another tab or another user" do
    second_token = SecureRandom.uuid
    @tenant.chat_presences.create!(token: @token, conversation_id: @mediation.id, expires_at: 30.seconds.from_now)
    @tenant.chat_presences.create!(token: second_token, conversation_id: @mediation.id, expires_at: 30.seconds.from_now)
    @mediation.landlord.chat_presences.create!(token: @token, conversation_id: @mediation.id, expires_at: 30.seconds.from_now)
    log_in_as(@tenant)
    delete presence_notifications_path, params: { token: @token }
    assert_response :no_content
    assert_equal [ second_token ], @tenant.chat_presences.pluck(:token)
    assert_equal 1, @mediation.landlord.chat_presences.count
  end

  test "private threads accept their participant and reject the other party" do
    string = MessageString.create!(Role: "Side")
    SideMessageGroup.create!(ConversationID: string.id, UserID: @tenant.UserID, MediatorID: @mediation.MediatorID)
    @mediation.update!(TenantSideConversationID: string.id)
    log_in_as(@tenant)
    patch presence_notifications_path, params: { token: @token, conversation_id: string.id }
    assert_response :no_content
    log_in_as(@mediation.landlord)
    patch presence_notifications_path, params: { token: SecureRandom.uuid, conversation_id: string.id }
    assert_response :forbidden
  end

  test "notification targets must be local paths" do
    notification = @notification
    [ "https://example.com", "//example.com", "/\\example.com", "/messages\n" ].each do |path|
      notification.action_path = path
      assert_not notification.valid?, "Unexpected valid target: #{path.inspect}"
    end
  end

  private

  def create_notification(user, title)
    user.notifications.create!(event: "new_message", title: title, body: "Open your conversation.",
                                conversation_id: primary_message_groups(:one).ConversationID,
                                action_path: messages_path)
  end
end
