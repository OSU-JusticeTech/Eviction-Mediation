require "test_helper"

class MediationSessionNotificationsTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    travel_to Time.zone.local(2026, 10, 22, 9)
    @conversation = primary_message_groups(:one)
    @mediator = @conversation.mediator
    MediatorScheduleAvailability.create!(MediatorID: @mediator.UserID, DayOfWeek: 1,
                                         StartTime: "09:00", EndTime: "17:00")
    @meeting = MediatorScheduledMeeting.new(MediatorID: @mediator.UserID,
                                            ConversationID: @conversation.ConversationID,
                                            StartTime: Time.zone.local(2026, 10, 26, 10),
                                            EndTime: Time.zone.local(2026, 10, 26, 10, 30), Status: "scheduled")
    clear_enqueued_jobs
  end

  teardown { travel_back }

  test "scheduling emails both parties and mediator and queues both reminders" do
    assert_enqueued_emails(3) { @meeting.save! }
    [ 24.hours, 1.hour ].each do |lead|
      assert_enqueued_with(job: MediationSessionReminderJob,
                           args: [ @meeting.id, @meeting.reminder_version, lead.to_i ],
                           at: @meeting.StartTime - lead)
    end
    [ @conversation.tenant, @conversation.landlord, @mediator ].each do |recipient|
      assert_enqueued_email_with MediationMailer, :session_notification,
        args: [ recipient, @conversation.ConversationID, "scheduled", @mediator,
                @meeting.StartTime, @meeting.EndTime, nil, nil ]
    end
  end

  test "rescheduling emails both parties and mediator with the previous times" do
    @meeting.save!
    previous = [ @meeting.StartTime, @meeting.EndTime ]
    @meeting.StartTime += 1.hour
    @meeting.EndTime += 1.hour
    assert_enqueued_emails 3 do
      assert_enqueued_email_with MediationMailer, :session_notification,
        args: [ @conversation.tenant, @conversation.ConversationID, "rescheduled", @mediator,
                @meeting.StartTime, @meeting.EndTime, nil, previous ] do
        @meeting.save!
      end
    end
    assert_enqueued_email_with MediationMailer, :session_notification,
      args: [ @mediator, @conversation.ConversationID, "rescheduled", @mediator,
              @meeting.StartTime, @meeting.EndTime, nil, previous ]
  end

  test "zoom-only changes send an update and unchanged saves do not repeat email" do
    @meeting.save!
    assert_enqueued_emails(3) { @meeting.update!(ZoomLink: "https://zoom.us/example") }
    assert_enqueued_email_with MediationMailer, :session_notification,
      args: [ @mediator, @conversation.ConversationID, "updated", @mediator,
              @meeting.StartTime, @meeting.EndTime, "https://zoom.us/example", nil ]
    assert_no_enqueued_emails { @meeting.save! }
  end

  test "cancellation notifies once and does not schedule reminders" do
    @meeting.save!
    clear_enqueued_jobs
    assert_enqueued_emails(3) { @meeting.update!(Status: "canceled") }
    assert_enqueued_email_with MediationMailer, :session_notification,
      args: [ @mediator, @conversation.ConversationID, "canceled", @mediator,
              @meeting.StartTime, @meeting.EndTime, nil, nil ]
    assert_enqueued_jobs 0, only: MediationSessionReminderJob
    assert_no_enqueued_emails { @meeting.update!(Status: "canceled") }
  end

  test "short notice scheduling queues only reminders whose time is still ahead" do
    travel_to @meeting.StartTime - 90.minutes
    @meeting.save!
    assert_enqueued_jobs 1, only: MediationSessionReminderJob
    assert_enqueued_with(job: MediationSessionReminderJob,
                         args: [ @meeting.id, @meeting.reminder_version, 1.hour.to_i ],
                         at: @meeting.StartTime - 1.hour)
  end

  test "late 24 hour jobs and reassigned cases do not send reminders" do
    @meeting.save!
    travel_to @meeting.StartTime - 30.minutes
    assert_no_enqueued_emails do
      MediationSessionReminderJob.perform_now(@meeting.id, @meeting.reminder_version, 24.hours.to_i)
    end
    @conversation.update!(MediatorID: users(:mediator2).UserID)
    assert_no_enqueued_emails do
      MediationSessionReminderJob.perform_now(@meeting.id, @meeting.reminder_version, 1.hour.to_i)
    end
  end

  test "failed and rolled back saves do not notify" do
    assert_no_enqueued_emails do
      @meeting.EndTime = @meeting.StartTime
      assert_not @meeting.save
    end
    @meeting.EndTime = @meeting.StartTime + 30.minutes
    assert_no_enqueued_jobs do
      MediatorScheduledMeeting.transaction(requires_new: true) do
        @meeting.save!
        raise ActiveRecord::Rollback
      end
    end
  end

  test "reminders go to both parties and mediator and skip obsolete or inactive meetings" do
    @meeting.save!
    version = @meeting.reminder_version
    travel_to @meeting.StartTime - 24.hours
    assert_enqueued_emails(3) { MediationSessionReminderJob.perform_now(@meeting.id, version, 24.hours.to_i) }
    assert_no_enqueued_emails { MediationSessionReminderJob.perform_now(@meeting.id, "obsolete", 24.hours.to_i) }
    @meeting.update!(StartTime: @meeting.StartTime + 1.hour, EndTime: @meeting.EndTime + 1.hour)
    assert_no_enqueued_emails { MediationSessionReminderJob.perform_now(@meeting.id, version, 24.hours.to_i) }
    version = @meeting.reminder_version
    @meeting.update!(Status: "canceled")
    assert_no_enqueued_emails { MediationSessionReminderJob.perform_now(@meeting.id, version, 24.hours.to_i) }
  end

  test "completed deleted past and closed-case meetings do not get reminders" do
    @meeting.save!
    travel_to @meeting.StartTime - 1.hour
    assert_enqueued_emails(3) { MediationSessionReminderJob.perform_now(@meeting.id, @meeting.reminder_version, 1.hour.to_i) }
    @meeting.update!(Status: "completed")
    assert_no_enqueued_emails { MediationSessionReminderJob.perform_now(@meeting.id, @meeting.reminder_version, 1.hour.to_i) }
    @meeting.update!(Status: "scheduled")
    @conversation.update!(deleted_at: Time.current)
    assert_no_enqueued_emails { MediationSessionReminderJob.perform_now(@meeting.id, @meeting.reminder_version, 1.hour.to_i) }
    @conversation.update!(deleted_at: nil)
    travel_to @meeting.StartTime + 1.minute
    assert_no_enqueued_emails { MediationSessionReminderJob.perform_now(@meeting.id, @meeting.reminder_version, 1.hour.to_i) }
    id = @meeting.id
    version = @meeting.reminder_version
    @meeting.destroy!
    assert_no_enqueued_emails { MediationSessionReminderJob.perform_now(id, version, 1.hour.to_i) }
  end
end
