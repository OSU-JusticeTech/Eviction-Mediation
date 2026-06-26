require "test_helper"

class UnreadMessageNotificationJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @tenant   = users(:tenant1)
    @landlord = users(:landlord1)
    ActionMailer::Base.deliveries.clear
    Rails.cache.clear

    # Reset preferences to defaults
    @tenant.update!(notify_unread_messages: true, notify_new_mediation_request: true)
    @landlord.update!(notify_unread_messages: true, notify_new_mediation_request: true)

    # Create a real IntakeQuestion to satisfy the FK constraint on PrimaryMessageGroups.IntakeID
    intake = IntakeQuestion.create!(
      UserID: @tenant.UserID,
      Reason: "Failure to Pay Rent",
      BestOption: "Pay Missed Rent",
      Section8: false,
      MoneyOwed: 1000.00,
      PayableToday: 500.00,
      TotalCostOrMonthly: false,
      MonthlyRent: 1000.00
    )

    # Active mediation between tenant1 and landlord1
    @mediation = primary_message_groups(:one)
    @mediation.update!(
      accepted_by_landlord: true,
      accepted_by_tenant: true,
      IntakeID: intake.IntakeID,
      deleted_at: nil
    )
  end

  teardown do
    ActionMailer::Base.deliveries.clear
    Rails.cache.clear
  end

  # --- notify_unread_messages: landlord side ---

  test "notifies landlord when unread tenant message is older than 4 hours and preference is on" do
    Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @tenant.UserID,
      recipientID: @landlord.UserID,
      MessageDate: 5.hours.ago,
      Contents: "hello landlord"
    )

    perform_enqueued_jobs { UnreadMessageNotificationJob.new.perform }

    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal @landlord.Email, ActionMailer::Base.deliveries.first.to.first
  end

  test "does not notify landlord when notify_unread_messages is disabled" do
    @landlord.update!(notify_unread_messages: false)

    Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @tenant.UserID,
      recipientID: @landlord.UserID,
      MessageDate: 5.hours.ago,
      Contents: "hello landlord"
    )

    UnreadMessageNotificationJob.new.perform

    assert_empty ActionMailer::Base.deliveries
  end

  test "does not notify landlord when tenant message is recent (under 4 hours)" do
    Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @tenant.UserID,
      recipientID: @landlord.UserID,
      MessageDate: 1.hour.ago,
      Contents: "just sent"
    )

    UnreadMessageNotificationJob.new.perform

    assert_empty ActionMailer::Base.deliveries
  end

  test "does not notify landlord when landlord has already replied" do
    old_tenant_msg = Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @tenant.UserID,
      recipientID: @landlord.UserID,
      MessageDate: 5.hours.ago,
      Contents: "hello"
    )
    Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @landlord.UserID,
      recipientID: @tenant.UserID,
      MessageDate: old_tenant_msg.MessageDate + 1.hour,
      Contents: "replied"
    )

    UnreadMessageNotificationJob.new.perform

    assert_empty ActionMailer::Base.deliveries
  end

  # --- notify_unread_messages: tenant side ---

  test "notifies tenant when unread landlord message is older than 4 hours and preference is on" do
    Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @landlord.UserID,
      recipientID: @tenant.UserID,
      MessageDate: 5.hours.ago,
      Contents: "hello tenant"
    )

    perform_enqueued_jobs { UnreadMessageNotificationJob.new.perform }

    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal @tenant.Email, ActionMailer::Base.deliveries.first.to.first
  end

  test "does not notify tenant when notify_unread_messages is disabled" do
    @tenant.update!(notify_unread_messages: false)

    Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @landlord.UserID,
      recipientID: @tenant.UserID,
      MessageDate: 5.hours.ago,
      Contents: "hello tenant"
    )

    UnreadMessageNotificationJob.new.perform

    assert_empty ActionMailer::Base.deliveries
  end

  test "skips mediations that are not fully active" do
    @mediation.update!(accepted_by_landlord: false)

    Message.create!(
      ConversationID: @mediation.ConversationID,
      SenderID: @tenant.UserID,
      recipientID: @landlord.UserID,
      MessageDate: 5.hours.ago,
      Contents: "hello"
    )

    UnreadMessageNotificationJob.new.perform

    assert_empty ActionMailer::Base.deliveries
  end
end
