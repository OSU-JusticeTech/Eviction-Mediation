module ApplicationCable
  class Channel < ActionCable::Channel::Base
    private

    # A custom stream callback replaces Action Cable's default transmitter.
    # Recheck outside the query cache before transmitting even queued payloads.
    def stream_with_authorization(broadcasting, &authorized)
      active = true
      stream_from broadcasting, coder: ActiveSupport::JSON do |payload|
        next unless active

        if ApplicationRecord.uncached { authorized.call }
          transmit payload
        else
          active = false
          stop_stream_from broadcasting
        end
      end
    end

    def subscription_user
      User.find_by(UserID: current_user.UserID) if current_user
    end
  end
end
