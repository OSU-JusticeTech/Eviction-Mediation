class MediatorTimeEntriesController < ApplicationController
  before_action :require_mediator
  before_action :set_entry, only: [ :heartbeat, :stop ]

  # POST /mediator_cases/:mediator_case_id/time_entries
  def create
    mediation = PrimaryMessageGroup.find_by(ConversationID: params[:mediator_case_id])

    unless mediation && mediation.MediatorID == @mediator_id
      redirect_to third_party_mediations_path, alert: "You are not assigned to this mediation."
      return
    end

    unless mediation.deleted_at.nil?
      redirect_to mediator_case_path(mediation), alert: "This mediation has ended."
      return
    end

    MediatorTimeEntry.start!(@mediator_id, mediation.ConversationID)
    redirect_to mediator_case_path(mediation), notice: "Time tracking started."
  end

  # PATCH /time_entries/:id/heartbeat
  def heartbeat
    return head :gone unless @entry.active?

    @entry.touch_activity!
    head :no_content
  end

  # PATCH /time_entries/:id/stop
  def stop
    if @entry.active?
      params[:reason] == "idle" ? @entry.close_for_inactivity! : @entry.close!
    end

    respond_to do |format|
      format.html { redirect_back fallback_location: mediator_case_path(@entry.ConversationID), notice: "Time tracking stopped." }
      format.json { head :no_content }
    end
  end

  private

  def require_mediator
    user = session[:user_id] && User.find_by(UserID: session[:user_id])

    unless user && user.Role == "Mediator"
      respond_to do |format|
        format.html { redirect_to(user ? dashboard_path : login_path, alert: "Access Denied") }
        format.json { head(user ? :forbidden : :unauthorized) }
      end
      return
    end

    @mediator_id = user.UserID
  end

  def set_entry
    @entry = MediatorTimeEntry.find_by(id: params[:id], MediatorID: @mediator_id)
    head :not_found unless @entry
  end
end
