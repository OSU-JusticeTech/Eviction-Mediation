require "test_helper"

class MessageNotificationTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @mediation = primary_message_groups(:one)
    @tenant = @mediation.tenant
    @landlord = @mediation.landlord
    @mediator = @mediation.mediator
  end

  test "direct messages email only their recipient after saving" do
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :new_message_notification,
        args: [ @landlord, @mediation.ConversationID, @tenant ] do
        create_message(recipientID: @landlord.UserID)
      end
    end
    notification = @landlord.notifications.sole
    assert_equal "new_message", notification.event
    assert_equal "/messages/#{@mediation.id}", notification.action_path
    assert_not_includes notification.body, "Private contents"
    assert_empty @tenant.notifications
    assert_empty @mediator.notifications
  end

  test "broadcast messages email the other party and assigned mediator" do
    assert_enqueued_emails(2) { create_message }
    assert_equal [ @landlord.UserID, @mediator.UserID ].sort, Notification.pluck(:user_id).sort
  end

  test "message email opt out is respected" do
    @landlord.update!(notify_unread_messages: false)
    assert_no_enqueued_emails { create_message(recipientID: @landlord.UserID) }
    assert_equal "new_message", @landlord.notifications.sole.event
  end

  test "closed cases and system messages do not generate new message emails" do
    assert_no_difference("Notification.count") do
      assert_no_enqueued_emails { create_message(is_system: true) }
    end
    @mediation.update!(deleted_at: Time.current)
    assert_no_difference("Notification.count") do
      assert_no_enqueued_emails { create_message }
    end
  end

  test "private mediator messages do not email the other party" do
    string = MessageString.create!(Role: "Side")
    SideMessageGroup.create!(ConversationID: string.ConversationID, UserID: @tenant.UserID, MediatorID: @mediation.MediatorID)
    @mediation.update!(TenantSideConversationID: string.ConversationID)
    assert_enqueued_emails 1 do
      assert_enqueued_email_with MediationMailer, :new_message_notification,
        args: [ @tenant, @mediation.ConversationID, @mediation.mediator ] do
        create_message(ConversationID: string.ConversationID, SenderID: @mediation.MediatorID, recipientID: @tenant.UserID)
      end
    end
    assert_equal @tenant.UserID, Notification.sole.user_id
    assert_empty @landlord.notifications
  end

  test "rolled back messages do not send emails" do
    assert_no_enqueued_emails do
      Message.transaction(requires_new: true) do
        create_message
        raise ActiveRecord::Rollback
      end
    end
    assert_empty Notification.all
  end

  test "viewing the exact chat suppresses the bell alert but preserves email" do
    @landlord.chat_presences.create!(conversation_id: @mediation.id, token: SecureRandom.uuid,
                                     expires_at: 30.seconds.from_now)
    assert_enqueued_emails 1 do
      assert_no_difference "Notification.count" do
        create_message(recipientID: @landlord.UserID)
      end
    end
  end

  test "another chat or expired presence does not suppress a message alert" do
    presence = @landlord.chat_presences.create!(conversation_id: @mediation.id + 999, token: SecureRandom.uuid,
                                               expires_at: 30.seconds.from_now)
    assert_difference("Notification.count", 1) { create_message(recipientID: @landlord.UserID) }
    presence.update!(conversation_id: @mediation.id, expires_at: 1.second.ago)
    assert_difference("Notification.count", 1) { create_message(recipientID: @landlord.UserID) }
  end

  test "viewing the main thread does not suppress a private mediator message" do
    string = MessageString.create!(Role: "Side")
    SideMessageGroup.create!(ConversationID: string.id, UserID: @tenant.UserID, MediatorID: @mediator.UserID)
    @mediation.update!(TenantSideConversationID: string.id)
    presence = @tenant.chat_presences.create!(conversation_id: @mediation.id, token: SecureRandom.uuid,
                                             expires_at: 30.seconds.from_now)
    attributes = { ConversationID: string.id, SenderID: @mediator.UserID, recipientID: @tenant.UserID }
    assert_difference("Notification.count", 1) { create_message(attributes) }
    presence.update!(conversation_id: string.id)
    assert_no_difference("Notification.count") { create_message(attributes) }
  end

  private

  def create_message(attributes = {})
    Message.create!({ ConversationID: @mediation.ConversationID, SenderID: @tenant.UserID,
                      MessageDate: Time.current, Contents: "Private contents" }.merge(attributes))
  end
end
