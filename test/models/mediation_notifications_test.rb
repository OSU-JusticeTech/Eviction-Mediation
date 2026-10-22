require "test_helper"

class MediationNotificationsTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper

  setup do
    @mediation = primary_message_groups(:one)
    activate_mediation(@mediation)
    @file = file_drafts(:one)
    clear_enqueued_jobs
  end

  test "linking or creating an agreement without sending it does not email anyone" do
    assert_no_enqueued_emails do
      @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
      @file.dup.tap { |file| file.FileID = nil }.save!
    end
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
  end

  test "first signature emails only the other party and final signature sends one completion per participant" do
    @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :agreement_notification,
        args: [ @mediation.landlord, @mediation.ConversationID, "agreement_signed", @file.FileID, @mediation.tenant ] do
        @file.update!(TenantSignature: true)
      end
    end
    assert_enqueued_emails 3 do
      @file.update!(LandlordSignature: true)
    end
    assert_no_enqueued_emails { @file.update!(LandlordSignature: true) }
  end

  test "landlord signature identifies landlord and goes only to tenant" do
    @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :agreement_notification,
        args: [ @mediation.tenant, @mediation.ConversationID, "agreement_signed", @file.FileID, @mediation.landlord ] do
        @file.update!(LandlordSignature: true)
      end
    end
  end

  test "closure and outcome updates exclude the actor and identify the correct event" do
    assert_enqueued_emails 2 do
      @mediation.update!(deleted_at: Time.current, EndedBy: @mediation.TenantID)
    end
    assert_enqueued_emails 2 do
      assert_enqueued_email_with MediationMailer, :case_closed_notification,
        args: [ @mediation.landlord, @mediation.ConversationID, PrimaryMessageGroup::OUTCOMES.first, @mediation.mediator, true ] do
        @mediation.update!(Outcome: PrimaryMessageGroup::OUTCOMES.first, notification_actor: @mediation.mediator)
      end
    end
  end

  test "standalone drafts do not notify participants" do
    assert_no_enqueued_emails { @file.update!(AgreementTemplate: "a", AgreementVersion: 1) }
  end

  test "each terminal outcome is emailed and unchanged outcomes do not repeat" do
    @mediation.update!(deleted_at: Time.current)
    PrimaryMessageGroup::OUTCOMES.each do |outcome|
      assert_enqueued_emails(3) { @mediation.update!(Outcome: outcome) }
      assert_no_enqueued_emails { @mediation.update!(Outcome: outcome) }
    end
  end

  test "rolled back case closure sends no notification" do
    assert_no_enqueued_emails do
      PrimaryMessageGroup.transaction(requires_new: true) do
        @mediation.update!(deleted_at: Time.current)
        raise ActiveRecord::Rollback
      end
    end
  end
end
