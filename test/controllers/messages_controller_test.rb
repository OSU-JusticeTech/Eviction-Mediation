require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = users(:tenant1) # Assume a fixture for a tenant user
    @landlord = users(:landlord1) # Assume a fixture for a landlord user
    @mediation = primary_message_groups(:one) # Assume a fixture for mediation
  end

  def log_in_as(user, expect_success: true)
    post login_path, params: { email: user[:Email], password: "password" }
    assert_redirected_to dashboard_url
    follow_redirect!
    assert_response(:success) if expect_success
  end

  test "should redirect to login if not logged in" do
    get messages_path
    assert_redirected_to login_path
    assert_equal "You must be logged in to access the dashboard.", flash[:alert]
  end

  test "tenant should see tenant_index if mediation exists" do
    log_in_as(@tenant)
    get messages_path
    assert_response :success
    assert_select "h1", "Tenant Negotiation & Messages"
  end

  test "tenant without mediation should see landlords list" do
    @mediation.update!(deleted_at: Time.current)
    log_in_as(@tenant)
    get messages_path
    assert_response :success
    assert_select "p.mediation-status", text: /No negotiations exist/i
  end

  test "landlord should see landlord_index if mediation exists" do
    log_in_as(@landlord)
    get messages_path
    assert_response :success
    assert_select "h1", "Landlord Negotiation & Messages"
  end

  test "unauthorized users should get forbidden response" do
    unauthorized_user = users(:random1)
    log_in_as(unauthorized_user, expect_success: false)
    get messages_path
    assert_response :forbidden
    assert_match "Access Denied", response.body
  end

  test "should get summary for ended mediation" do
    @mediation.update!(deleted_at: Time.current)
    log_in_as(@tenant)
    get mediation_summary_path(@mediation.ConversationID)
    assert_response :success
    assert_select "h1", "Mediation Summary"
  end

  test "should redirect active mediation summary" do
    log_in_as(@tenant)
    get mediation_summary_path(@mediation.ConversationID)
    assert_redirected_to messages_path
  end

  test "mediator is redirected from index" do
    mediator = users(:mediator1)
    log_in_as(mediator)

    get messages_path

    assert_redirected_to third_party_mediations_path
  end

  test "show returns not found when conversation does not exist" do
    log_in_as(@tenant)

    get message_path(999_999)

    assert_response :not_found
    assert_match "Conversation not found", response.body
  end

  test "show forbids users outside the conversation" do
    outsider = users(:tenant2)
    log_in_as(outsider)

    get message_path(@mediation.ConversationID)

    assert_response :forbidden
    assert_match "Access Denied", response.body
  end

  test "request mediator succeeds when not yet requested" do
    @mediation.update!(MediatorRequested: false, MediatorAssigned: false)
    log_in_as(@tenant)

    patch request_mediator_message_path(@mediation)

    assert_redirected_to messages_path
    assert_equal true, @mediation.reload.MediatorRequested
  end

  test "request mediator does not duplicate request" do
    @mediation.update!(MediatorRequested: true, MediatorAssigned: true)
    log_in_as(@tenant)

    patch request_mediator_message_path(@mediation)

    assert_redirected_to messages_path
    assert_equal "Mediator already requested or assigned.", flash[:alert]
  end

  test "create returns duplicate accepted for repeated json message" do
    log_in_as(@tenant)
    Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @tenant.UserID,
      recipientID: @landlord.UserID,
      MessageDate: Time.current,
      Contents: "dupe-content"
    )

    post messages_path,
      params: { ConversationID: @mediation.ConversationID, Contents: "dupe-content" },
      as: :json

    assert_response :accepted
  end

  test "create returns not found for missing conversation" do
    log_in_as(@tenant)
    orphan_string = MessageString.create!(Role: "Primary")

    post messages_path,
      params: { ConversationID: orphan_string.ConversationID, Contents: "hello" },
      as: :json

    assert_response :not_found
  end

  test "past mediations denies non tenant" do
    log_in_as(@landlord)

    get past_mediations_path

    assert_redirected_to messages_path
    assert_equal "Access Denied", flash[:alert]
  end

  test "landlord past mediations denies non landlord" do
    log_in_as(@tenant)

    get landlord_past_mediations_path

    assert_redirected_to messages_path
    assert_equal "Access Denied", flash[:alert]
  end

  test "show renders conversation for tenant participant" do
    log_in_as(@tenant)

    get message_path(@mediation.ConversationID)

    assert_response :success
  end

  test "show redirects to ended prompt for deleted mediation" do
    @mediation.update!(deleted_at: Time.current)
    log_in_as(@tenant)

    get message_path(@mediation.ConversationID)

    assert_redirected_to mediation_ended_prompt_path(@mediation.ConversationID)
  end

  test "show denies mediator not assigned to conversation" do
    @mediation.update!(MediatorID: users(:mediator2).UserID)
    log_in_as(users(:mediator1))

    get message_path(@mediation.ConversationID)

    assert_response :forbidden
  end

  test "create json denies outsider" do
    outsider = users(:tenant2)
    log_in_as(outsider)

    post messages_path,
      params: { ConversationID: @mediation.ConversationID, Contents: "blocked" },
      as: :json

    assert_response :forbidden
  end

  test "create html redirects to conversation on success" do
    log_in_as(@tenant)

    assert_difference("Message.count", 1) do
      post messages_path, params: { ConversationID: @mediation.ConversationID, Contents: "hello html" }
    end

    assert_redirected_to message_path(@mediation.ConversationID)
  end

  test "request mediator redirects to ended prompt when mediation deleted" do
    @mediation.update!(deleted_at: Time.current)
    log_in_as(@tenant)

    patch request_mediator_message_path(@mediation)

    assert_redirected_to mediation_ended_prompt_path(@mediation.ConversationID)
  end

  test "ended mediation summary denies outsider" do
    @mediation.update!(deleted_at: Time.current)
    outsider = users(:tenant2)
    log_in_as(outsider)

    get mediation_summary_path(@mediation.ConversationID)

    assert_response :forbidden
  end

  test "past mediations renders for tenant" do
    @mediation.update!(deleted_at: Time.current)
    log_in_as(@tenant)

    get past_mediations_path

    assert_response :success
  end

  test "landlord past mediations renders for landlord" do
    @mediation.update!(deleted_at: Time.current)
    log_in_as(@landlord)

    get landlord_past_mediations_path

    assert_response :success
  end
end
