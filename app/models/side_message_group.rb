class SideMessageGroup < ApplicationRecord
    self.table_name = "SideMessageGroups"
    self.primary_key = "ConversationID"

    # Retired private conversations remain stored, but cannot carry new activity.
    def self.find_live_for(user, conversation_id)
      return unless user

      group = find_by(ConversationID: conversation_id, deleted_at: nil)
      return unless group && [group.UserID, group.MediatorID].include?(user.UserID)
      return unless MessageString.exists?(ConversationID: group.ConversationID, Role: "Side", deleted_at: nil)

      cases = PrimaryMessageGroup.where(deleted_at: nil, MediatorAssigned: true, MediatorID: group.MediatorID)
      mediation = cases.find_by(TenantSideConversationID: group.ConversationID, TenantID: group.UserID) ||
        cases.find_by(LandlordSideConversationID: group.ConversationID, LandlordID: group.UserID)
      return unless mediation && MessageString.exists?(ConversationID: mediation.ConversationID, Role: "Primary", deleted_at: nil)

      group
    end
end
