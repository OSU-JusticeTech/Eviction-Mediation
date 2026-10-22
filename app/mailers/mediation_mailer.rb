class MediationMailer < ApplicationMailer
  default from: Rails.application.credentials.dig(:smtp, :from) || "no-reply@example.com"

  AGREEMENT_EVENTS = {
    "agreement_created" => [ "Agreement preview created", "An agreement preview is available for your review." ],
    "agreement_approved" => [ "Agreement changes approved", "Suggested changes to the agreement have been approved." ],
    "agreement_revised" => [ "Agreement preview revised", "The agreement has been revised. Please review the latest version." ],
    "agreement_changes_requested" => [ "Agreement requires changes", "Changes have been proposed to the agreement. Please review and respond in the application." ],
    "agreement_ready" => [ "Agreement ready for signing", "The agreement is ready for signing. Review the current terms before signing." ],
    "agreement_signed" => [ "A party signed the agreement", "A party has signed the agreement. Sign in to review its signature status." ],
    "agreement_completed" => [ "Agreement signatures completed", "Both parties have signed the agreement." ]
  }.freeze

  def agreement_notification(recipient, conversation_id, event, file_id)
    @recipient = recipient
    @title, @description = AGREEMENT_EVENTS.fetch(event)
    @conversation_id = conversation_id
    @action_url = view_file_url(file_id)
    mail(to: recipient.Email, subject: @title, template_name: "event_notification")
  end

  def new_message_notification(recipient, conversation_id)
    @recipient = recipient
    @title = "New mediation message"
    @description = "You have a new message. Sign in to read and respond."
    @conversation_id = conversation_id
    @action_url = messages_url
    mail(to: recipient.Email, subject: @title, template_name: "event_notification")
  end

  def case_closed_notification(recipient, conversation_id, outcome)
    @recipient = recipient
    @title = "Mediation case closed"
    @description = "Your mediation case has been closed."
    @details = outcome.presence || "The case outcome has not yet been recorded."
    @conversation_id = conversation_id
    @action_url = messages_url
    mail(to: recipient.Email, subject: @title, template_name: "event_notification")
  end

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
