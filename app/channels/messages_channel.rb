class MessagesChannel < ApplicationCable::Channel
  def subscribed
    @conversation_id = params[:conversation_id]
    return reject unless authorized?

    stream_with_authorization("messages_#{@conversation_id}") { authorized? }
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  private

  def authorized?
    user = subscription_user
    return false unless user

    group = PrimaryMessageGroup.find_by(ConversationID: @conversation_id, deleted_at: nil)
    return false unless group && MessageString.exists?(ConversationID: group.ConversationID, Role: "Primary", deleted_at: nil)

    @conversation_id = group.ConversationID
    return true if user.admin?
    return true if user.mediator? && group.MediatorAssigned? && group.MediatorID == user.UserID
    return false unless [group.TenantID, group.LandlordID].include?(user.UserID)

    !%w[Tenant Landlord].include?(user.Role) || group.active?
  end
end
