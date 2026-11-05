# Deliver both channels from the same event so recipient/privacy rules stay in
# the existing callers. Email preferences only control the email channel.
class MediationNotifications
  class << self
    delegate :view_file_path, :message_path, :messages_path, :mediator_case_path,
             :mediation_summary_path, to: "Rails.application.routes.url_helpers"

    def agreement_notification(recipient, conversation_id, event, file_id, actor, *details)
      title, description = MediationMailer::AGREEMENT_EVENTS.fetch(event)
      name = actor_name(actor)
      body = description % { actor: name }
      body = body.gsub("Sign in to review", "Review").gsub(" in the application", "")
      body = [ body, *Array(details[0]), details[1] ].compact_blank.join("\n")
      create(recipient, conversation_id, event, title % { actor: name }, body, view_file_path(file_id))
      MediationMailer.agreement_notification(recipient, conversation_id, event, file_id, actor, *details).deliver_later
    end

    def new_message_notification(recipient, conversation_id, sender, source_conversation_id: conversation_id)
      name = actor_name(sender)
      unless ChatPresence.viewing?(recipient.UserID, source_conversation_id)
        create(recipient, conversation_id, "new_message", "New message from #{name}",
               "#{name} sent you a message. Open the conversation to read and respond.",
               message_path(conversation_id))
      end
      if recipient.notify_unread_messages?
        MediationMailer.new_message_notification(recipient, conversation_id, sender).deliver_later
      end
    end

    def case_closed_notification(recipient, conversation_id, outcome, actor = nil, outcome_updated = false)
      title = outcome_updated ? "Mediation case outcome updated" : "Mediation case closed"
      description = if outcome_updated
        actor ? "#{actor_name(actor)} updated the case outcome." : "The case outcome has been updated."
      else
        actor ? "#{actor_name(actor)} closed the case." : "Your mediation case has been closed."
      end
      body = "#{description}\n#{outcome.presence || 'The case outcome has not yet been recorded.'}"
      path = recipient.mediator? ? mediator_case_path(conversation_id) : mediation_summary_path(conversation_id)
      create(recipient, conversation_id, outcome_updated ? "case_outcome_updated" : "case_closed", title, body, path)
      MediationMailer.case_closed_notification(recipient, conversation_id, outcome, actor, outcome_updated).deliver_later
    end

    def session_notification(recipient, conversation_id, event, actor, start_time, end_time, zoom_link, *previous_times)
      title, description = MediationMailer::SESSION_EVENTS.fetch(event)
      times = [ "Starts: #{session_time(start_time)}", "Ends: #{session_time(end_time)}" ]
      if previous_times.first
        times << "Previous time: #{session_time(previous_times.first.first)} to #{session_time(previous_times.first.last)}"
      end
      times << "Join meeting: #{zoom_link}" if zoom_link.present? && event != "canceled"
      body = [ description % { actor: actor_name(actor) }, *times ].join("\n")
      create(recipient, conversation_id, "session_#{event}", title, body, message_path(conversation_id))
      MediationMailer.session_notification(recipient, conversation_id, event, actor,
                                           start_time, end_time, zoom_link, *previous_times).deliver_later
    end

    def mediation_request_notification(recipient, conversation, requester)
      create(recipient, conversation.ConversationID, "mediation_request", "New mediation request",
             "#{actor_name(requester)} requested a negotiation with you. Review the request to respond.", messages_path)
      return unless recipient.notify_new_mediation_request?

      if recipient.landlord?
        LandlordMailer.mediation_request_notification(recipient.Email, requester).deliver_later
      else
        TenantMailer.invitation_email(recipient.Email, requester).deliver_later
      end
    end

    def mediator_assignment_notification(recipient, conversation_id, mediator, reassigned = false)
      title = reassigned ? "New mediator assigned to your case" : "Mediator assigned to your case"
      body = "#{actor_name(mediator)} has been assigned to your mediation case. Open the conversation to view your case."
      create(recipient, conversation_id, "mediator_assigned", title, body, message_path(conversation_id))
    end

    private

    def create(recipient, conversation_id, event, title, body, action_path)
      recipient.notifications.create!(conversation_id: conversation_id, event: event, title: title,
                                      body: body, action_path: action_path)
    end

    def actor_name(actor)
      return "A participant" unless actor

      name = [ actor.FName, actor.LName ].compact.join(" ").squish.presence || actor.Role
      "#{name} (#{actor.Role.to_s.capitalize})"
    end

    def session_time(time)
      time.in_time_zone.strftime("%B %-d, %Y at %-I:%M %p %Z (UTC%:z)")
    end
  end
end
