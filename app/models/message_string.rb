class MessageString < ApplicationRecord
    self.table_name = "MessageStrings"
    self.primary_key = "ConversationID"
end
