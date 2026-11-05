class ChatPresence < ApplicationRecord
  belongs_to :user, primary_key: :UserID

  def self.viewing?(user_id, conversation_id)
    where(user_id: user_id, conversation_id: conversation_id).where("expires_at > ?", Time.current).exists?
  end
end
