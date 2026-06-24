class DashboardController < ApplicationController
    before_action :require_login
    before_action :set_user

    def index
      case @user.Role
      when "Landlord"
        render "dashboard/index"
      when "Tenant"
        render "dashboard/index"
      when "Admin"
        render "dashboard/index"
      when "Mediator"
        if @user.mediator.present?
          @active_mediations = PrimaryMessageGroup
            .where(MediatorID: @user.UserID, MediatorAssigned: true, deleted_at: nil)
            .includes(:tenant, :landlord)
            .sort_by { |m| -m.last_activity_at.to_i }
        end
        render "dashboard/index"
      else
        render plain: "Error: Invalid user role", status: :forbidden
      end
    end

    def destroy
      session[:user_id] = nil  # Remove the user from the session
      redirect_to root_path, notice: "You have been logged out."  # Redirect to home page or login page
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
end
