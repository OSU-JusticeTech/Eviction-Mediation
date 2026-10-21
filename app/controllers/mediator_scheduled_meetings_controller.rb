class MediatorScheduledMeetingsController < ApplicationController
  before_action :require_mediator

  # GET /mediator_scheduled_meetings
  def index
    meetings = MediatorScheduledMeeting
      .where(MediatorID: @mediator_id)
      .order(:StartTime)

    render json: meetings
  end

  # POST /mediator_scheduled_meetings
  def create
    meeting = MediatorScheduledMeeting.new(meeting_params)
    meeting[:MediatorID] = @mediator_id
    meeting[:Status] = "scheduled"

    if meeting.save
      render json: meeting, status: :created
    else
      render json: { errors: meeting.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # PATCH /mediator_scheduled_meetings/:id
  def update
    meeting = MediatorScheduledMeeting.find_by(
      id: params[:id],
      MediatorID: @mediator_id
    )

    return head :not_found unless meeting

    unless meeting[:Status] == "scheduled"
      render json: { error: "Only scheduled meetings can be updated" },
             status: :unprocessable_entity
      return
    end

    if meeting.update(meeting_params)
      render json: meeting
    else
      render json: { errors: meeting.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # PATCH /mediator_scheduled_meetings/:id/cancel
  def cancel
    meeting = MediatorScheduledMeeting.find_by(
      id: params[:id],
      MediatorID: @mediator_id
    )

    return head :not_found unless meeting

    unless meeting[:Status] == "scheduled"
      render json: { error: "Only scheduled meetings can be canceled" },
             status: :unprocessable_entity
      return
    end

    if meeting.update(Status: "canceled")
      render json: meeting
    else
      render json: { errors: meeting.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  private

  def require_mediator
    unless session[:user_id]
      render json: { error: "Login required" },
             status: :unauthorized
      return
    end

    user = User.find_by(UserID: session[:user_id])

    unless user && user.Role == "Mediator"
      render json: { error: "Mediator access required" },
             status: :forbidden
      return
    end

    @mediator_id = user.UserID
  end

  def meeting_params
    params.require(:meeting).permit(
      :ConversationID,
      :StartTime,
      :EndTime,
      :ZoomLink
    )
  end
end
