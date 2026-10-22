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

  test "sharing a preview notifies all participants that it is created and ready" do
    assert_enqueued_emails 6 do
      @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
    end
  end

  test "first signature notifies participants and second also sends completion" do
    @file.update!(AgreementConversationID: @mediation.ConversationID, AgreementVersion: 1, AgreementTemplate: "a")
    assert_enqueued_emails(3) { @file.update!(TenantSignature: true) }
    assert_enqueued_emails(6) { @file.update!(LandlordSignature: true) }
    assert_no_enqueued_emails { @file.update!(LandlordSignature: true) }
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
