class UserActivityLog < ApplicationRecord
    self.table_name = "UserActivityLogs"
    self.primary_key = "LogID"
end
