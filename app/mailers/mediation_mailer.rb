class MediationMailer < ApplicationMailer
  default from: Rails.application.credentials.dig(:smtp, :from) || "no-reply@example.com"

  AGREEMENT_EVENTS = {
    "agreement_shared" => [ "Agreement shared for review", "%{actor} shared an agreement with you. Sign in to review its terms and signature status." ],
    "agreement_suggestions_pending" => [ "Agreement has pending suggestions", "%{actor} sent suggestions for the agreement. Review and respond in the application." ],
    "agreement_revised" => [ "Agreement preview revised", "%{actor} accepted suggestions and revised the agreement. The changes are listed below." ],
    "agreement_ready" => [ "Agreement ready for signing", "%{actor} finished reviewing the suggestions. No suggestions remain pending; the agreement is ready for signing." ],
    "agreement_signed" => [ "%{actor} signed the agreement", "%{actor} signed the agreement. Review the current terms and sign when you are ready." ],
    "agreement_completed" => [ "Agreement signatures completed", "%{actor} added the final signature. Both parties have now signed the agreement." ]
  }.freeze

  def agreement_notification(recipient, conversation_id, event, file_id, actor, changes = [], signing_status = nil)
    @recipient = recipient
    title, description = AGREEMENT_EVENTS.fetch(event)
    @title = title % { actor: notification_actor_name(actor) }
    @description = description % { actor: notification_actor_name(actor) }
    @changes = changes
    @details = signing_status
    @conversation_id = conversation_id
    @action_url = view_file_url(file_id)
    mail(to: recipient.Email, subject: @title, template_name: "event_notification")
  end

  def new_message_notification(recipient, conversation_id, sender)
    @recipient = recipient
    @title = "New message from #{notification_actor_name(sender)}"
    @description = "#{notification_actor_name(sender)} sent you a message. Sign in to read and respond."
    @conversation_id = conversation_id
    @action_url = messages_url
    mail(to: recipient.Email, subject: @title, template_name: "event_notification")
  end

  def case_closed_notification(recipient, conversation_id, outcome, actor = nil, outcome_updated = false)
    @recipient = recipient
    @title = outcome_updated ? "Mediation case outcome updated" : "Mediation case closed"
    @description = if outcome_updated
      actor ? "#{notification_actor_name(actor)} updated the case outcome." : "The case outcome has been updated."
    else
      actor ? "#{notification_actor_name(actor)} closed the case." : "Your mediation case has been closed."
    end
    @details = outcome.presence || "The case outcome has not yet been recorded."
    @conversation_id = conversation_id
    @action_url = messages_url
    mail(to: recipient.Email, subject: @title, template_name: "event_notification")
  end

  def session_notification(recipient, conversation_id, event, actor, start_time, end_time, zoom_link, previous_times = nil)
    @recipient = recipient
    @title, @description = case event
    when "scheduled"
      [ "Mediation session scheduled", "#{notification_actor_name(actor)} scheduled a mediation session." ]
    when "rescheduled"
      [ "Mediation session rescheduled", "#{notification_actor_name(actor)} changed the mediation session time." ]
    when "updated"
      [ "Mediation session updated", "#{notification_actor_name(actor)} updated the mediation session details." ]
    when "canceled"
      [ "Mediation session canceled", "#{notification_actor_name(actor)} canceled the mediation session. Do not attend at the previously scheduled time." ]
    when "reminder_24h"
      [ "Mediation session reminder: 24 hours", "Your mediation session is scheduled to start in 24 hours." ]
    when "reminder_1h"
      [ "Mediation session reminder: 1 hour", "Your mediation session is scheduled to start in 1 hour." ]
    else
      raise ArgumentError, "Unknown session notification event: #{event}"
    end
    @changes = [ "Starts: #{session_time(start_time)}", "Ends: #{session_time(end_time)}" ]
    if previous_times
      @changes << "Previous time: #{session_time(previous_times.first)} to #{session_time(previous_times.last)}"
    end
    @changes << "Join meeting: #{zoom_link}" if zoom_link.present? && event != "canceled"
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

  private

  def session_time(time)
    time.in_time_zone.strftime("%B %-d, %Y at %-I:%M %p %Z (UTC%:z)")
  end

  def notification_actor_name(actor)
    return "A participant" unless actor

    name = [ actor.FName, actor.LName ].compact.join(" ").squish
    name = actor.Role if name.blank?
    "#{name} (#{actor.Role.to_s.capitalize})"
  end
end
