class Message < ApplicationRecord
  self.table_name = "messages"
  self.primary_key = "MessageID"

  has_many :file_attachments, foreign_key: :MessageID, dependent: :destroy
  has_many :file_drafts, through: :file_attachments

  after_create_commit :notify_new_message

  def notification_mediation
    return if self.ConversationID.nil?

    PrimaryMessageGroup.find_by(ConversationID: self.ConversationID) ||
      PrimaryMessageGroup.find_by(TenantSideConversationID: self.ConversationID) ||
      PrimaryMessageGroup.find_by(LandlordSideConversationID: self.ConversationID)
  end

  def notification_recipients
    mediation = notification_mediation
    return [] unless mediation && !mediation.past?

    if mediation.ConversationID == self.ConversationID
      return [] unless mediation.notification_participants.any? { |user| user.UserID == self.SenderID }

      mediation.notification_participants.select do |user|
        user.UserID != self.SenderID && (self.recipientID.nil? || user.UserID == self.recipientID)
      end
    else
      side = SideMessageGroup.find_by(ConversationID: self.ConversationID, deleted_at: nil)
      return [] unless side && mediation.MediatorAssigned? && side.MediatorID == mediation.MediatorID
      return [] unless [ mediation.TenantID, mediation.LandlordID ].include?(side.UserID)
      return [] unless [ side.UserID, side.MediatorID ].include?(self.SenderID)

      User.where(UserID: [ side.UserID, side.MediatorID ] - [ self.SenderID ]).to_a
    end
  end

  private

  def notify_new_message
    return if self.is_system?

    mediation = notification_mediation
    return unless mediation && !mediation.past?

    notification_recipients.each do |recipient|
      next unless recipient.notify_unread_messages?

      MediationMailer.new_message_notification(recipient, mediation.ConversationID).deliver_later
    end
  end
end
