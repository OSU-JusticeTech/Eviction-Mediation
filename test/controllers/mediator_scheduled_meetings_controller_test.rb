require "test_helper"

class MediatorScheduledMeetingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @mediator_id = 4
    mediator = User.find_by!(UserID: @mediator_id)

    post login_path, params: {
      email: mediator.Email,
      password: "password"
    }
    assert_response :redirect

    @conversation = PrimaryMessageGroup.find_by!(
      MediatorID: @mediator_id
    )

    MediatorScheduleAvailability.create!(
      MediatorID: @mediator_id,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )
  end

  def meeting_params
    {
      meeting: {
        ConversationID: @conversation.ConversationID,
        StartTime: "2026-10-26 10:00:00",
        EndTime: "2026-10-26 10:30:00"
      }
    }
  end

  def create_meeting
    MediatorScheduledMeeting.create!(
      MediatorID: @mediator_id,
      ConversationID: @conversation.ConversationID,
      StartTime: "2026-10-26 10:00:00",
      EndTime: "2026-10-26 10:30:00",
      Status: "scheduled"
    )
  end

  test "creates scheduled meeting" do
    assert_difference "MediatorScheduledMeeting.count", 1 do
      post mediator_scheduled_meetings_path, params: meeting_params
    end

    assert_response :created
    assert_equal "scheduled", response.parsed_body["Status"]
  end

  test "lists own meetings" do
    create_meeting

    get mediator_scheduled_meetings_path

    assert_response :success
    assert_equal 1, response.parsed_body.length
  end

  test "updates scheduled meeting" do
    meeting = create_meeting

    patch mediator_scheduled_meeting_path(meeting),
          params: {
            meeting: {
              StartTime: "2026-10-26 11:00:00",
              EndTime: "2026-10-26 11:30:00"
            }
          }

    assert_response :success
    assert_equal 11, meeting.reload.StartTime.hour
  end

  test "cancels scheduled meeting" do
    meeting = create_meeting

    patch cancel_mediator_scheduled_meeting_path(meeting)

    assert_response :success
    assert_equal "canceled", meeting.reload.Status
  end

  test "rejects overlapping meeting" do
    create_meeting

    params = meeting_params
    params[:meeting][:StartTime] = "2026-10-26 10:15:00"
    params[:meeting][:EndTime] = "2026-10-26 10:45:00"

    assert_no_difference "MediatorScheduledMeeting.count" do
      post mediator_scheduled_meetings_path, params: params
    end

    assert_response :unprocessable_entity
  end

  test "rejects meeting during blocked period" do
    MediatorScheduleBlock.create!(
      MediatorID: @mediator_id,
      StartTime: "2026-10-26 10:00:00",
      EndTime: "2026-10-26 11:00:00"
    )

    post mediator_scheduled_meetings_path, params: meeting_params

    assert_response :unprocessable_entity
  end

  test "rejects meeting outside availability" do
    params = meeting_params
    params[:meeting][:StartTime] = "2026-10-26 18:00:00"
    params[:meeting][:EndTime] = "2026-10-26 18:30:00"

    post mediator_scheduled_meetings_path, params: params

    assert_response :unprocessable_entity
  end

  test "cannot update canceled meeting" do
    meeting = create_meeting
    meeting.update!(Status: "canceled")

    patch mediator_scheduled_meeting_path(meeting),
          params: { meeting: { ZoomLink: "https://zoom.us/test" } }

    assert_response :unprocessable_entity
  end

  test "cannot cancel meeting twice" do
    meeting = create_meeting
    meeting.update!(Status: "canceled")

    patch cancel_mediator_scheduled_meeting_path(meeting)

    assert_response :unprocessable_entity
  end

  test "cannot impersonate another mediator" do
    params = meeting_params
    params[:meeting][:MediatorID] = 8

    post mediator_scheduled_meetings_path, params: params

    assert_response :created
    assert_equal 4, response.parsed_body["MediatorID"]
  end

  test "cannot update another mediators meeting" do
    other_conversation = PrimaryMessageGroup.find_by!(MediatorID: 8)

    MediatorScheduleAvailability.create!(
      MediatorID: 8,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    meeting = MediatorScheduledMeeting.create!(
      MediatorID: 8,
      ConversationID: other_conversation.ConversationID,
      StartTime: "2026-10-26 10:00:00",
      EndTime: "2026-10-26 10:30:00",
      Status: "scheduled"
    )

    patch mediator_scheduled_meeting_path(meeting),
          params: { meeting: { ZoomLink: "https://zoom.us/test" } }

    assert_response :not_found
    assert_nil meeting.reload.ZoomLink
  end

  test "cannot cancel another mediators meeting" do
    other_conversation = PrimaryMessageGroup.find_by!(MediatorID: 8)

    MediatorScheduleAvailability.create!(
      MediatorID: 8,
      DayOfWeek: 1,
      StartTime: "09:00",
      EndTime: "17:00"
    )

    meeting = MediatorScheduledMeeting.create!(
      MediatorID: 8,
      ConversationID: other_conversation.ConversationID,
      StartTime: "2026-10-26 10:00:00",
      EndTime: "2026-10-26 10:30:00",
      Status: "scheduled"
    )

    patch cancel_mediator_scheduled_meeting_path(meeting)

    assert_response :not_found
    assert_equal "scheduled", meeting.reload.Status
  end

  test "requires login to access scheduled meetings" do
    delete logout_path

    get mediator_scheduled_meetings_path

    assert_response :unauthorized
    assert_equal "Login required", response.parsed_body["error"]
  end

  test "rejects non mediator access to scheduled meetings" do
    delete logout_path

    landlord = User.find_by!(UserID: 1)
    post login_path, params: {
      email: landlord.Email,
      password: "password"
    }

    assert_response :redirect

    get mediator_scheduled_meetings_path

    assert_response :forbidden
    assert_equal "Mediator access required", response.parsed_body["error"]
  end
end
