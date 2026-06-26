class AddNotificationPreferencesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :Users, :notify_unread_messages, :boolean, default: true, null: false
    add_column :Users, :notify_new_mediation_request, :boolean, default: true, null: false
  end
end
