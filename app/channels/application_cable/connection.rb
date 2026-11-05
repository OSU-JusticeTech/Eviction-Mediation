module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = User.find_by(UserID: request.session[:user_id]) if request.session[:user_id].present?
      reject_unauthorized_connection unless current_user
    end
  end
end
