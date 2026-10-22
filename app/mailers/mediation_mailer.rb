class MediationMailer < ApplicationMailer
  def unread_message_notification(email, recipient, sender, conversation_id)
    @recipient = recipient
    @sender = sender
    @conversation_id = conversation_id
    @messages_url = messages_url

    mail(
      to: email,
      subject: "You have an unread message in your ongoing mediation"
    )
  end
end
