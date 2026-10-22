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
    mediation = notification_mediation
    return unless mediation && !mediation.past?

    sender = User.find_by(UserID: self.SenderID)
    agreements = file_drafts.select do |file|
      file.agreement_document? && file.agreement_conversation_id == mediation.ConversationID
    end
    if agreements.any? && self.ConversationID == mediation.ConversationID
      # The agreement email replaces the generic message email, including for
      # the system message used when generating and sharing in one action.
      recipients = notification_recipients.select { |user| [ mediation.TenantID, mediation.LandlordID ].include?(user.UserID) }
      agreements.each do |file|
        status = if file.TenantSignature && file.LandlordSignature
          "Both parties have already signed this agreement."
        elsif file.agreement_suggestions_pending?
          "Suggestions remain pending. Review them before signing."
        else
          "The agreement is ready for signing. You can also suggest changes before signing."
        end
        recipients.each do |recipient|
          MediationMailer.agreement_notification(recipient, mediation.ConversationID, "agreement_shared", file.FileID, sender, [], status).deliver_later
        end
      end
      return
    end
    return if self.is_system?

    notification_recipients.each do |recipient|
      next unless recipient.notify_unread_messages?

      MediationMailer.new_message_notification(recipient, mediation.ConversationID, sender).deliver_later
    end
  end
end
