class FileAttachment < ApplicationRecord
    self.table_name = "FileAttachments"
    self.primary_key = [:FileID, :MessageID]

    # Associations
    belongs_to :file_draft, foreign_key: :FileID
    belongs_to :message, foreign_key: :MessageID

    # Validations
    validates :FileID, presence: true
    validates :MessageID, presence: true, uniqueness: { scope: :FileID }
end
