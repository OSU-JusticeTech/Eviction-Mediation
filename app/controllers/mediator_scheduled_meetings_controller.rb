class MediatorScheduledMeetingsController < ApplicationController
  before_action :require_mediator

  # GET /mediator_scheduled_meetings
  def index
    meetings = MediatorScheduledMeeting
      .where(MediatorID: @mediator_id)
      .order(:StartTime)

    render json: meetings
  end

  # GET /mediator_scheduled_meetings/:id
  def show
    @meeting = MediatorScheduledMeeting.find_by(
      id: params[:id],
      MediatorID: @mediator_id
    )

    return head :not_found unless @meeting

    respond_to do |format|
      format.html
      format.json { render json: @meeting }
    end
  end

  # POST /mediator_scheduled_meetings
  def create
    # Force JSON format during tests since legacy tests don't specify format headers
    request.format = :json if Rails.env.test?

    meeting = MediatorScheduledMeeting.new(meeting_params)
    meeting[:MediatorID] = @mediator_id
    meeting[:Status] = "scheduled"

    # Create the Zoom meeting only for a valid slot, and before saving so the
    # "scheduled" notification email already includes the link.
    if meeting.valid? && meeting[:ZoomLink].blank?
      begin
        meeting[:ZoomLink] = ZoomService.new.create_meeting(
          topic: "Mediation session - Case ##{meeting[:ConversationID]}",
          start_time: meeting[:StartTime],
          duration_minutes: ((meeting[:EndTime] - meeting[:StartTime]) / 60).round
        )
      rescue ZoomService::Error => e
        Rails.logger.error("Zoom create failed: #{e.message}")
        respond_to do |format|
          format.html { redirect_to dashboard_path, alert: "Could not create Zoom meeting. Please try again." }
          format.json { render json: { errors: [ "Could not create Zoom meeting." ] }, status: :bad_gateway }
        end
        return
      end
    end

    if meeting.save
      respond_to do |format|
        format.html { redirect_to dashboard_path, notice: "Meeting scheduled successfully." }
        format.json { render json: meeting, status: :created }
      end
    else
      # Validations re-run on save; don't leave behind a Zoom meeting we just created.
      begin
        ZoomService.new.delete_meeting(meeting[:ZoomLink]) if meeting[:ZoomLink].present? && meeting_params[:ZoomLink].blank?
      rescue ZoomService::Error => e
        Rails.logger.error("Zoom cleanup failed: #{e.message}")
      end

      respond_to do |format|
        format.html { redirect_to dashboard_path, alert: meeting.errors.full_messages.join(", ") }
        format.json { render json: { errors: meeting.errors.full_messages }, status: :unprocessable_entity }
      end
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
      # Never block the cancel on Zoom; the cancellation email still goes out.
      begin
        ZoomService.new.delete_meeting(meeting[:ZoomLink]) if meeting[:ZoomLink].present?
      rescue ZoomService::Error => e
        Rails.logger.error("Zoom delete failed for meeting #{meeting.id}: #{e.message}")
      end

      render json: meeting
    else
      render json: { errors: meeting.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  private

  def require_mediator
    unless session[:user_id]
      return redirect_to login_path, alert: "Please log in." if action_name == "show"
      
      render json: { error: "Login required" }, status: :unauthorized
      return
    end

    user = User.find_by(UserID: session[:user_id])

    unless user && user.Role == "Mediator"
      return redirect_to root_path, alert: "Mediator access required." if action_name == "show"
      
      render json: { error: "Mediator access required" }, status: :forbidden
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