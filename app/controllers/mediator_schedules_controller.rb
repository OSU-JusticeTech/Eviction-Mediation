class MediatorSchedulesController < ApplicationController
  before_action :require_mediator

  def edit
    @assigned_cases = PrimaryMessageGroup
      .where(MediatorID: @user.UserID, MediatorAssigned: true, deleted_at: nil)
      .order(ConversationID: :desc)
  end

  private

  def require_mediator
    unless session[:user_id]
      redirect_to login_path, alert: "Please log in."
      return
    end

    @user = User.find_by(UserID: session[:user_id])

    unless @user&.Role == "Mediator"
      redirect_to root_path, alert: "Mediator access required."
    end
  end
end