class MediatorMessagesChannel < ApplicationCable::Channel
  def subscribed
    @conversation_id = params[:conversation_id]
    return reject unless authorized?

    stream_with_authorization("side_messages_#{@conversation_id}") { authorized? }
  end

  def unsubscribed
    # Cleanup
  end

  private

  def authorized?
    group = SideMessageGroup.find_live_for(subscription_user, @conversation_id)
    return false unless group

    @conversation_id = group.ConversationID
    true
  end
end
