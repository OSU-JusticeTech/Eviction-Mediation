class MediatorCasesController < ApplicationController
  before_action :require_login
  before_action :set_user
  before_action :authorize_mediator_or_admin
  before_action :set_mediation, only: [ :show ]

  def show
    @mediation = PrimaryMessageGroup.find(params[:id])

    # Prevents edge case unauthorized access to a mediation a mediator is no
    # longer assigned to. Admins have read-only oversight of every case, so the
    # assignment check does not apply to them.
    if @user.Role == "Mediator" && @mediation.MediatorID != @user.UserID
      redirect_to third_party_mediations_path, alert: "You are no longer assigned to this mediation."
      return
    end

    participant_ids = [
      @user.UserID,
      @mediation.TenantID,
      @mediation.LandlordID,
      @mediation.MediatorID
    ].compact.uniq

    @conversation_participants = User.where(UserID: participant_ids).index_by(&:UserID)
  end


  private

  def set_mediation
    @mediation = PrimaryMessageGroup.find(params[:id])
  end

  def require_login
    unless session[:user_id]
      redirect_to login_path, alert: "You must be logged in to access the dashboard."
    end
  end

  def set_user
    @user = User.find(session[:user_id])
  end

  def authorize_mediator_or_admin
    unless [ "Mediator", "Admin" ].include?(@user.Role)
      redirect_to dashboard_path, alert: "Access Denied"
    end
  end
end
