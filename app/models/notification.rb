class Notification < ApplicationRecord
  belongs_to :user, foreign_key: :user_id, primary_key: :UserID

  validates :event, :title, :body, :action_path, presence: true
  validates :action_path, format: { with: %r{\A/(?!/)[^\\\r\n]*\z} }

  scope :unread, -> { where(read_at: nil) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def unread?
    read_at.nil?
  end

  def mark_as_read!
    self.class.where(id: id, read_at: nil).update_all(read_at: Time.current)
  end
end
