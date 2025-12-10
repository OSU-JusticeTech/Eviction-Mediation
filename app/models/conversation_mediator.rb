class ConversationMediator < ApplicationRecord
    self.table_name = "ConversationMediators"
    self.primary_key = "MediatedConversationID"
end
