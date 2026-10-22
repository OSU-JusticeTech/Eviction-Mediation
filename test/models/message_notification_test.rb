require "test_helper"

class MessageNotificationTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @mediation = primary_message_groups(:one)
    @tenant = @mediation.tenant
    @landlord = @mediation.landlord
  end

  test "direct messages email only their recipient after saving" do
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :new_message_notification,
        args: [ @landlord, @mediation.ConversationID, @tenant ] do
        create_message(recipientID: @landlord.UserID)
      end
    end
  end

  test "broadcast messages email the other party and assigned mediator" do
    assert_enqueued_emails(2) { create_message }
  end

  test "message email opt out is respected" do
    @landlord.update!(notify_unread_messages: false)
    assert_no_enqueued_emails { create_message(recipientID: @landlord.UserID) }
  end

  test "closed cases and system messages do not generate new message emails" do
    assert_no_enqueued_emails { create_message(is_system: true) }
    @mediation.update!(deleted_at: Time.current)
    assert_no_enqueued_emails { create_message }
  end

  test "private mediator messages do not email the other party" do
    string = MessageString.create!(Role: "Side")
    @mediation.update!(TenantSideConversationID: string.ConversationID)
    SideMessageGroup.create!(ConversationID: string.ConversationID, UserID: @tenant.UserID, MediatorID: @mediation.MediatorID)
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :new_message_notification,
        args: [ @tenant, @mediation.ConversationID, @mediation.mediator ] do
        create_message(ConversationID: string.ConversationID, SenderID: @mediation.MediatorID, recipientID: @tenant.UserID)
      end
    end
  end

  test "rolled back messages do not send emails" do
    assert_no_enqueued_emails do
      Message.transaction(requires_new: true) do
        create_message
        raise ActiveRecord::Rollback
      end
    end
  end

  private

  def create_message(attributes = {})
    Message.create!({ ConversationID: @mediation.ConversationID, SenderID: @tenant.UserID,
                      MessageDate: Time.current, Contents: "Private contents" }.merge(attributes))
  end
end
