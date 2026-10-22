class MediatorScheduleBlocksController < ApplicationController
  before_action :require_mediator

  # GET /mediator_schedule_blocks
  def index
    blocks = MediatorScheduleBlock
      .where(MediatorID: @mediator_id)
      .order(:StartTime)

    render json: blocks
  end

  # POST /mediator_schedule_blocks
  def create
    block = MediatorScheduleBlock.new(block_params)
    block[:MediatorID] = @mediator_id

    if block.save
      render json: block, status: :created
    else
      render json: { errors: block.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # PATCH /mediator_schedule_blocks/:id
  def update
    block = MediatorScheduleBlock.find_by(
      id: params[:id],
      MediatorID: @mediator_id
    )

    return head :not_found unless block

    if block.update(block_params)
      render json: block
    else
      render json: { errors: block.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # DELETE /mediator_schedule_blocks/:id
  def destroy
    block = MediatorScheduleBlock.find_by(
      id: params[:id],
      MediatorID: @mediator_id
    )

    return head :not_found unless block

    block.destroy!
    head :no_content
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

  def block_params
    params.require(:block).permit(
      :StartTime,
      :EndTime,
      :Reason
    )
  end
end
