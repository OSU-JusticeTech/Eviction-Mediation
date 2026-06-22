class MediatorAvailabilityController < ApplicationController
  before_action :require_login
  before_action :set_user
  before_action :verify_mediator

  def update
    if @user.update(availability_params)
      flash[:notice] = "Availability updated."
    else
      flash[:alert] = "Failed to update availability."
    end
    redirect_to dashboard_path
  end

  private

  def require_login
    unless session[:user_id]
      redirect_to login_path, alert: "You must be logged in."
    end
  end

  def set_user
    @user = User.find(session[:user_id])
  end

  def verify_mediator
    redirect_to dashboard_path unless @user.Role == "Mediator"
  end

  def availability_params
    params.require(:user).permit(mediator_attributes: [:id, :Available])
  end
end
