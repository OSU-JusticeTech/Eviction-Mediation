class FileDraft < ApplicationRecord
  self.table_name  = "FileDrafts"
  self.primary_key = 'FileID'

  has_many :file_attachments, foreign_key: :FileID
  has_many :messages, through: :file_attachments

  def uploaded_at
    self[:CreatedAt] || self[:created_at] || self[:UpdatedAt] || self[:updated_at]
  end
end
