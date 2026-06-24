class ThirdPartyMediationsController < ApplicationController
  before_action :require_login
  before_action :set_user
  before_action :authorize_mediator

  def index
    mediations = PrimaryMessageGroup
      .where(MediatorID: @user.UserID, MediatorAssigned: true)
      .includes(:tenant, :landlord)
      .sort_by { |m| [ m.past? ? 1 : 0, -(m.last_activity_at.to_i) ] }

    @grouped_mediations  = mediations.group_by { |m| m.past? ? :past : :active }
    @has_past_mediations = mediations.any?(&:past?)
    @show_mediation_view = mediations.any?

    render "third_party_mediations/index"
  end

  private

  def require_login
    unless session[:user_id]
      redirect_to login_path, alert: "You must be logged in to access the dashboard."
    end
  end

  def set_user
    @user = User.find(session[:user_id])
  end

  def authorize_mediator
    unless @user.Role == "Mediator"
      redirect_to dashboard_path, alert: "Access Denied"
    end
  end
end
