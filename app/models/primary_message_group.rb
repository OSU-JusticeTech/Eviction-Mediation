class PrimaryMessageGroup < ApplicationRecord
  self.table_name = "PrimaryMessageGroups"
  self.primary_key = "ConversationID"
  validates :ConversationID, :TenantID, :LandlordID, presence: true
  validates :accepted_by_landlord, inclusion: { in: [ true, false ] }
  validates :accepted_by_tenant, inclusion: { in: [ true, false ] }
  belongs_to :intake_question, foreign_key: "IntakeID", optional: true
  belongs_to :tenant, class_name: "User", foreign_key: "TenantID"
  belongs_to :landlord, class_name: "User", foreign_key: "LandlordID"
  belongs_to :mediator, class_name: "User", foreign_key: "MediatorID", optional: true
  belongs_to :linked_message_string, foreign_key: "ConversationID", primary_key: "ConversationID", class_name: "MessageString", optional: true
end
