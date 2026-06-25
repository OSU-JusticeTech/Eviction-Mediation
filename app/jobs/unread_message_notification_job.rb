class UnreadMessageNotificationJob < ApplicationJob
  queue_as :default

  def perform
    # Find all active mediations (not deleted, both parties accepted)
    active_mediations = PrimaryMessageGroup.where(
      deleted_at: nil,
      accepted_by_landlord: true,
      accepted_by_tenant: true
    ).where("IntakeID IS NOT NULL") # Only mediations that have started (intake completed)

    active_mediations.each do |mediation|
      check_and_notify_landlord(mediation)
      check_and_notify_tenant(mediation)
    end
  end

  private

  def check_and_notify_landlord(mediation)
    # Find the last message sent by the tenant to the landlord
    last_tenant_message = Message.where(
      ConversationID: mediation.ConversationID,
      SenderID: mediation.TenantID,
      recipientID: mediation.LandlordID
    ).order(MessageDate: :desc).first

    return unless last_tenant_message

    # Check if message is older than 4 hours
    if last_tenant_message.MessageDate < 4.hours.ago
      # Check if we've already sent a notification for this message
      # We'll use a simple check: if the landlord has sent a message after this one, they've seen it
      landlord_response = Message.where(
        ConversationID: mediation.ConversationID,
        SenderID: mediation.LandlordID
      ).where("MessageDate > ?", last_tenant_message.MessageDate).exists?

      return if landlord_response

      # Check if we've already sent a notification (store in a separate table or use a flag)
      # For now, we'll send it once per message by checking if notification was sent in last 24 hours
      recent_notification = last_notification_sent_at(mediation.LandlordID, mediation.ConversationID)

      if recent_notification.nil? || recent_notification < last_tenant_message.MessageDate
        if mediation.landlord.notify_unread_messages?
          MediationMailer.unread_message_notification(
            mediation.landlord.Email,
            mediation.landlord,
            mediation.tenant,
            mediation.ConversationID
          ).deliver_later
        end

        record_notification(mediation.LandlordID, mediation.ConversationID)
      end
    end
  end

  def check_and_notify_tenant(mediation)
    # Find the last message sent by the landlord to the tenant
    last_landlord_message = Message.where(
      ConversationID: mediation.ConversationID,
      SenderID: mediation.LandlordID,
      recipientID: mediation.TenantID
    ).order(MessageDate: :desc).first

    return unless last_landlord_message

    # Check if message is older than 4 hours
    if last_landlord_message.MessageDate < 4.hours.ago
      # Check if we've already sent a notification for this message
      # We'll use a simple check: if the tenant has sent a message after this one, they've seen it
      tenant_response = Message.where(
        ConversationID: mediation.ConversationID,
        SenderID: mediation.TenantID
      ).where("MessageDate > ?", last_landlord_message.MessageDate).exists?

      return if tenant_response

      # Check if we've already sent a notification
      recent_notification = last_notification_sent_at(mediation.TenantID, mediation.ConversationID)

      if recent_notification.nil? || recent_notification < last_landlord_message.MessageDate
        if mediation.tenant.notify_unread_messages?
          MediationMailer.unread_message_notification(
            mediation.tenant.Email,
            mediation.tenant,
            mediation.landlord,
            mediation.ConversationID
          ).deliver_later
        end

        record_notification(mediation.TenantID, mediation.ConversationID)
      end
    end
  end

  def last_notification_sent_at(user_id, conversation_id)
    # Store in Rails cache with a key based on user and conversation
    Rails.cache.read("unread_notification:#{user_id}:#{conversation_id}")
  end

  def record_notification(user_id, conversation_id)
    # Store the current time in cache (expires in 7 days)
    Rails.cache.write(
      "unread_notification:#{user_id}:#{conversation_id}",
      Time.current,
      expires_in: 7.days
    )
  end
end
