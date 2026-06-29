class DashboardController < ApplicationController
    before_action :require_login
    before_action :set_user

    def index
      response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
      case @user.Role
      when "Landlord"
        load_landlord_dashboard_data
        render "dashboard/index"
      when "Tenant"
        load_tenant_dashboard_data
        render "dashboard/index"
      when "Admin"
        render "dashboard/index"
      when "Mediator"
        if @user.mediator.present?
          @active_mediations = PrimaryMessageGroup
            .where(MediatorID: @user.UserID, MediatorAssigned: true, deleted_at: nil)
            .includes(:tenant, :landlord, :linked_message_string)
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

    def load_tenant_dashboard_data
      mediations = PrimaryMessageGroup
        .where(TenantID: @user.UserID, deleted_at: nil)
        .includes(:landlord, :linked_message_string)
        .to_a

      @active_mediation = mediations
        .select(&:active?)
        .max_by { |m| m.linked_message_string&.LastMessageSentDate || m.CreatedAt || Time.at(0) }

      pending = mediations.select(&:pending?)
      @pending_mediation_count = pending.length
      @pending_mediation = pending.max_by { |m| m.CreatedAt || Time.at(0) }

      return unless @active_mediation

      @latest_message = Message
        .where(ConversationID: @active_mediation.ConversationID)
        .where("is_system IS NULL OR is_system = 0")
        .order(MessageDate: :desc)
        .first

      @message_sender = User.find_by(UserID: @latest_message.SenderID) if @latest_message

      user_last_sent_at = Message
        .where(ConversationID: @active_mediation.ConversationID, SenderID: @user.UserID)
        .maximum(:MessageDate)

      session_read_at = session["conversation_read_at_#{@active_mediation.ConversationID}"]
        &.then { |t| Time.at(t) }

      cutoff = [ user_last_sent_at, session_read_at ].compact.max

      @new_message_count = Message
        .where(ConversationID: @active_mediation.ConversationID)
        .where.not(SenderID: @user.UserID)
        .where("is_system IS NULL OR is_system = 0")
        .yield_self { |q| cutoff ? q.where("MessageDate > ?", cutoff) : q }
        .count
    end

    def load_landlord_dashboard_data
      all_mediations = PrimaryMessageGroup
        .where(LandlordID: @user.UserID, deleted_at: nil)
        .includes(:tenant, :linked_message_string)
        .to_a

      @landlord_active_conversations = all_mediations
        .select(&:active?)
        .sort_by { |m| -(m.linked_message_string&.LastMessageSentDate || m.CreatedAt || Time.at(0)).to_i }
        .first(3)

      pending = all_mediations.select(&:pending?).sort_by { |m| -(m.CreatedAt || Time.at(0)).to_i }
      @landlord_pending_count = pending.length
      @landlord_pending_conversations = pending.first(3)
    end

    def require_login
      unless session[:user_id]
        redirect_to login_path, alert: "You must be logged in to access the dashboard."
      end
    end

    def set_user
      @user = User.find(session[:user_id])
    end
end
