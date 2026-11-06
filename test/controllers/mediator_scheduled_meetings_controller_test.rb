require "test_helper"
require "minitest/mock"

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

  class FakeZoom
    attr_reader :deleted

    def initialize(join_url: nil, error: false, on_create: nil)
      @join_url = join_url
      @error = error
      @on_create = on_create
      @deleted = []
    end

    def create_meeting(**)
      raise ZoomService::Error, "boom" if @error
      @on_create&.call
      @join_url
    end

    def delete_meeting(join_url)
      raise ZoomService::Error, "boom" if @error
      @deleted << join_url
    end
  end

  test "create stores Zoom join url" do
    zoom = FakeZoom.new(join_url: "https://us02web.zoom.us/j/123456789")

    ZoomService.stub(:new, zoom) do
      post mediator_scheduled_meetings_path, params: meeting_params
    end

    assert_response :created
    assert_equal "https://us02web.zoom.us/j/123456789", response.parsed_body["ZoomLink"]
    assert_equal "https://us02web.zoom.us/j/123456789", MediatorScheduledMeeting.last.ZoomLink
  end

  test "create deletes Zoom meeting when save fails" do
    # A conflicting meeting is saved while Zoom is being called, so save fails validation.
    zoom = FakeZoom.new(join_url: "https://us02web.zoom.us/j/123456789", on_create: -> { create_meeting })

    ZoomService.stub(:new, zoom) do
      post mediator_scheduled_meetings_path, params: meeting_params
    end

    assert_response :unprocessable_entity
    assert_equal [ "https://us02web.zoom.us/j/123456789" ], zoom.deleted
  end

  test "create returns bad gateway and saves nothing when Zoom fails" do
    ZoomService.stub(:new, FakeZoom.new(error: true)) do
      assert_no_difference "MediatorScheduledMeeting.count" do
        post mediator_scheduled_meetings_path, params: meeting_params
      end
    end

    assert_response :bad_gateway
    assert_includes response.parsed_body["errors"].first, "Zoom"
  end

  test "cancel deletes the Zoom meeting" do
    meeting = create_meeting
    meeting.update!(ZoomLink: "https://us02web.zoom.us/j/123456789")
    zoom = FakeZoom.new

    ZoomService.stub(:new, zoom) do
      patch cancel_mediator_scheduled_meeting_path(meeting)
    end

    assert_response :success
    assert_equal [ "https://us02web.zoom.us/j/123456789" ], zoom.deleted
  end

  test "cancel succeeds even when Zoom delete fails" do
    meeting = create_meeting
    meeting.update!(ZoomLink: "https://us02web.zoom.us/j/123456789")

    ZoomService.stub(:new, FakeZoom.new(error: true)) do
      patch cancel_mediator_scheduled_meeting_path(meeting)
    end

    assert_response :success
    assert_equal "canceled", meeting.reload.Status
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
