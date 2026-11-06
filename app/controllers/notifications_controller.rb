class NotificationsController < ApplicationController
  before_action :require_login
  before_action :disable_caching

  PER_PAGE = 20

  def index
    @unread_count = current_user.notifications.unread.count
    @unread_only = params[:filter] == "unread"
    @page = [ params[:page].to_i, 1 ].max
    scope = current_user.notifications.newest_first
    scope = scope.unread if @unread_only
    entries = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
    @has_next_page = entries.length > PER_PAGE
    @notifications = entries.first(PER_PAGE)
  end

  def menu
    render partial: "notifications/menu", locals: { user: current_user }
  end

  def update
    current_user.notifications.find(params[:id]).mark_as_read!
    redirect_to notifications_path(filter: params[:filter], page: params[:page]), status: :see_other
  end

  def open
    notification = current_user.notifications.find(params[:id])
    notification.mark_as_read!
    redirect_to notification.action_path, status: :see_other, allow_other_host: false
  end

  def mark_all_read
    current_user.notifications.unread.update_all(read_at: Time.current)
    redirect_to notifications_path, status: :see_other, notice: "All notifications marked as read."
  end

  def presence
    return head :bad_request unless params[:token].to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)

    scope = current_user.chat_presences
    if request.delete?
      scope.where(token: params[:token]).delete_all
    else
      # The same membership rules apply to messages and visible-chat tracking.
      message = Message.new(ConversationID: params[:conversation_id], SenderID: current_user.UserID)
      return head :forbidden if message.notification_recipients.empty?

      scope.where("expires_at <= ?", Time.current).delete_all
      scope.find_or_initialize_by(token: params[:token]).update!(
        conversation_id: message.ConversationID, expires_at: 30.seconds.from_now)
    end
    head :no_content
  end

  private

  def require_login
    redirect_to login_path, alert: "Please sign in to view your notifications." unless current_user
  end

  def disable_caching
    response.headers["Cache-Control"] = "no-store"
  end
end
