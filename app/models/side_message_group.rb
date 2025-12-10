class SideMessageGroup < ApplicationRecord
    self.table_name = "SideMessageGroups"
    self.primary_key = "ConversationID"
end
