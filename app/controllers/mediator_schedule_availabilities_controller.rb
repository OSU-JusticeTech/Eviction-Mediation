class MediatorScheduleAvailabilitiesController < ApplicationController
  before_action :require_mediator

  # GET /mediator_schedule_availabilities
  def index
    availabilities = MediatorScheduleAvailability
      .where(MediatorID: @mediator_id)
      .order(:DayOfWeek, :StartTime)

    render json: availabilities
  end

  # POST /mediator_schedule_availabilities
  def create
    availability = MediatorScheduleAvailability.new(availability_params)
    availability[:MediatorID] = @mediator_id

    if availability.save
      render json: availability, status: :created
    else
      render json: { errors: availability.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # PATCH /mediator_schedule_availabilities/:id
  def update
    availability = MediatorScheduleAvailability.find_by(
      id: params[:id],
      MediatorID: @mediator_id
    )

    return head :not_found unless availability

    if availability.update(availability_params)
      render json: availability
    else
      render json: { errors: availability.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # DELETE /mediator_schedule_availabilities/:id
  def destroy
    availability = MediatorScheduleAvailability.find_by(
      id: params[:id],
      MediatorID: @mediator_id
    )

    return head :not_found unless availability

    availability.destroy!
    head :no_content
  end

  private

  def require_mediator
    unless session[:user_id]
      render json: { error: "Login required" }, status: :unauthorized
      return
    end

    user = User.find_by(UserID: session[:user_id])

    unless user && user.Role == "Mediator"
      render json: { error: "Mediator access required" }, status: :forbidden
      return
    end

    @mediator_id = user.UserID
  end

  def availability_params
    params.require(:availability).permit(
      :DayOfWeek,
      :StartTime,
      :EndTime
    )
  end
end
