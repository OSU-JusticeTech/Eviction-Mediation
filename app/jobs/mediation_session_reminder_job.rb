class MediationSessionReminderJob < ApplicationJob
  queue_as :default

  def perform(meeting_id, expected_version, lead_time)
    return unless [ 24.hours.to_i, 1.hour.to_i ].include?(lead_time)

    meeting = MediatorScheduledMeeting.find_by(id: meeting_id)
    return unless meeting && meeting[:Status] == "scheduled"
    return unless meeting.reminder_version == expected_version && meeting[:StartTime].future?
    return if meeting.conversation.past? || meeting.conversation.MediatorID != meeting[:MediatorID]

    # If a delayed 24-hour job runs inside the 1-hour window, use only the
    # later reminder rather than sending both together.
    return if lead_time == 24.hours.to_i && meeting[:StartTime] <= 1.hour.from_now

    actor = User.find_by(UserID: meeting[:MediatorID])
    event = lead_time == 24.hours.to_i ? "reminder_24h" : "reminder_1h"
    meeting.notification_recipients.each do |recipient|
      MediationMailer.session_notification(recipient, meeting[:ConversationID], event, actor,
                                           meeting[:StartTime], meeting[:EndTime], meeting[:ZoomLink]).deliver_later
    end
  end
end
