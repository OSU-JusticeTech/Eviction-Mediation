require "test_helper"

class MediationNotificationsTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper

  setup do
    @mediation = primary_message_groups(:one)
    activate_mediation(@mediation)
    @file = file_drafts(:one)
    @tenant, @landlord, @mediator = @mediation.tenant, @mediation.landlord, @mediation.mediator
    clear_enqueued_jobs
  end

  test "linking or creating an agreement without sending it does not email anyone" do
    assert_no_enqueued_emails do
      @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
      @file.dup.tap { |file| file.FileID = nil }.save!
    end
    assert_empty Notification.all
  end

  test "sharing an agreement sends only one email to the other party" do
    @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
    [ false, true ].each do |system_message|
      assert_enqueued_emails 1 do
        assert_enqueued_email_with MediationMailer, :agreement_notification,
          args: [ @mediation.tenant, @mediation.ConversationID, "agreement_shared", @file.FileID, @mediation.landlord, [],
                  "The agreement is ready for signing. You can also suggest changes before signing." ] do
          Message.transaction do
            message = Message.create!(ConversationID: @mediation.ConversationID, SenderID: @mediation.LandlordID,
                                      MessageDate: Time.current, Contents: "Please review", is_system: system_message)
            FileAttachment.create!(MessageID: message.MessageID, FileID: @file.FileID)
          end
        end
      end
    end
    assert_equal 2, @tenant.notifications.where(event: "agreement_shared").count
    assert_empty Notification.where(event: "new_message")
  end

  test "first signature emails only the other party and final signature sends one completion per participant" do
    @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :agreement_notification,
        args: [ @mediation.landlord, @mediation.ConversationID, "agreement_signed", @file.FileID, @mediation.tenant ] do
        @file.update!(TenantSignature: true)
      end
    end
    assert_equal "agreement_signed", @landlord.notifications.sole.event
    assert_enqueued_emails 3 do
      @file.update!(LandlordSignature: true)
    end
    assert_equal [ @tenant.UserID, @landlord.UserID, @mediator.UserID ].sort,
                 Notification.where(event: "agreement_completed").pluck(:user_id).sort
    assert_no_difference("Notification.count") do
      assert_no_enqueued_emails { @file.update!(LandlordSignature: true) }
    end
  end

  test "landlord signature identifies landlord and goes only to tenant" do
    @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :agreement_notification,
        args: [ @mediation.tenant, @mediation.ConversationID, "agreement_signed", @file.FileID, @mediation.landlord ] do
        @file.update!(LandlordSignature: true)
      end
    end
    assert_equal "agreement_signed", @tenant.notifications.sole.event
  end

  test "closure and outcome updates exclude the actor and identify the correct event" do
    assert_enqueued_emails 2 do
      @mediation.update!(deleted_at: Time.current, EndedBy: @mediation.TenantID)
    end
    assert_empty @tenant.notifications
    assert_equal "case_closed", @landlord.notifications.sole.event
    assert_enqueued_emails 2 do
      assert_enqueued_email_with MediationMailer, :case_closed_notification,
        args: [ @mediation.landlord, @mediation.ConversationID, PrimaryMessageGroup::OUTCOMES.first, @mediation.mediator, true ] do
        @mediation.update!(Outcome: PrimaryMessageGroup::OUTCOMES.first, notification_actor: @mediation.mediator)
      end
    end
  end

  test "standalone drafts do not notify participants" do
    assert_no_enqueued_emails { @file.update!(AgreementTemplate: "a", AgreementVersion: 1) }
    assert_empty Notification.all
  end

  test "each terminal outcome is emailed and unchanged outcomes do not repeat" do
    @mediation.update!(deleted_at: Time.current)
    PrimaryMessageGroup::OUTCOMES.each do |outcome|
      assert_enqueued_emails(3) { @mediation.update!(Outcome: outcome) }
      assert_includes @tenant.notifications.newest_first.first.body, outcome
      assert_no_difference("Notification.count") do
        assert_no_enqueued_emails { @mediation.update!(Outcome: outcome) }
      end
    end
  end

  test "rolled back case closure sends no notification" do
    assert_no_enqueued_emails do
      PrimaryMessageGroup.transaction(requires_new: true) do
        @mediation.update!(deleted_at: Time.current)
        raise ActiveRecord::Rollback
      end
    end
    assert_empty Notification.all
  end

  test "assigning and replacing a mediator notifies both parties once" do
    @mediation.update!(MediatorAssigned: false, MediatorID: nil)
    assert_difference "Notification.count", 2 do
      @mediation.update!(MediatorAssigned: true, MediatorID: @mediator.UserID)
    end
    assert_equal [ @tenant.UserID, @landlord.UserID ].sort,
                 Notification.where(event: "mediator_assigned").pluck(:user_id).sort
    notification = @tenant.notifications.sole
    assert_equal "Mediator assigned to your case", notification.title
    assert_includes notification.body, @mediator.FName
    assert_equal "/messages/#{@mediation.id}", notification.action_path
    assert_no_difference("Notification.count") { @mediation.save! }
    assert_difference "Notification.count", 2 do
      @mediation.update!(MediatorID: users(:mediator2).UserID)
    end
    assert_equal "New mediator assigned to your case", @tenant.notifications.newest_first.first.title
    assert_no_difference "Notification.count" do
      @mediation.update!(MediatorAssigned: false, MediatorID: nil)
    end
  end

  test "rolled back mediator assignments do not notify" do
    @mediation.update!(MediatorAssigned: false, MediatorID: nil)
    assert_no_difference "Notification.count" do
      PrimaryMessageGroup.transaction(requires_new: true) do
        @mediation.update!(MediatorAssigned: true, MediatorID: @mediator.UserID)
        raise ActiveRecord::Rollback
      end
    end
  end

  test "agreement review events include revisions and signing status" do
    %w[agreement_suggestions_pending agreement_revised agreement_ready].each do |event|
      assert_difference "@landlord.notifications.count", 1 do
        MediationNotifications.agreement_notification(@landlord, @mediation.ConversationID, event,
          @file.FileID, @tenant, [ "Amount owed changed to $500" ], "No suggestions remain pending.")
      end
      notification = @landlord.notifications.newest_first.first
      assert_equal event, notification.event
      assert_includes notification.body, "Amount owed changed to $500"
      assert_includes notification.body, "No suggestions remain pending."
    end
  end
end
