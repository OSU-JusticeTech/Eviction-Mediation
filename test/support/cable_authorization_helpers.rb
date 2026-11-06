# Exercise real Rails stream decoding and transmission: ChannelStub discards callbacks.
module CableAuthorizationHelpers
  class InlineExecutor
    def post(&block)
      block.call
    end

    def async_invoke(receiver, method, *args, **)
      receiver.public_send(method, *args)
    end
  end

  class LocalPubSub
    attr_reader :callbacks

    def initialize
      @callbacks = Hash.new { |hash, key| hash[key] = [] }
    end

    def subscribe(name, callback, success)
      callbacks[name] << callback
      success.call
    end

    def unsubscribe(name, callback)
      callbacks[name].delete(callback)
    end

    def broadcast(name, payload)
      callbacks[name].dup.each { |callback| callback.call(ActiveSupport::JSON.encode(payload)) }
    end
  end

  def subscribe_as(user, params = {}, channel_class: self.class.channel_class, cable_connection: nil, **subscription_params)
    unless cable_connection
      cable_connection = ActionCable::Channel::ConnectionStub.new(current_user: user)
      pubsub = LocalPubSub.new
      executor = InlineExecutor.new
      server = Struct.new(:event_loop, :config).new(executor, ActionCable.server.config)
      cable_connection.define_singleton_method(:pubsub) { pubsub }
      cable_connection.define_singleton_method(:server) { server }
      cable_connection.define_singleton_method(:worker_pool) { executor }
    end
    @connection = cable_connection
    @cable_subscription_count = (@cable_subscription_count || 0) + 1
    @subscription = channel_class.new(connection, "security_#{@cable_subscription_count}",
      params.merge(subscription_params).with_indifferent_access)
    subscription.subscribe_to_channel
    subscription
  end

  def assert_allowed(stream)
    assert subscription.send(:subscription_confirmation_sent?)
    assert subscription.send(:streams).key?(stream)
  end

  def assert_denied
    assert subscription.send(:subscription_rejected?)
    assert_empty subscription.send(:streams)
  end

  def payloads(channel = subscription)
    channel.connection.transmissions.filter_map do |entry|
      entry["message"] if entry["identifier"] == channel.identifier
    end
  end

  def build_security_case
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediator = users(:mediator1)
    @other_mediator = users(:mediator2)
    @outsider = users(:tenant2)
    @admin = users(:admin1)
    @case = primary_message_groups(:one)
    MessageString.find(@case.ConversationID).update!(Role: "Primary", deleted_at: nil)
    activate_mediation(@case)
    @case.update!(MediatorID: @mediator.UserID, MediatorAssigned: true)
    string = MessageString.create!(Role: "Side")
    @side = SideMessageGroup.create!(ConversationID: string.ConversationID,
      UserID: @tenant.UserID, MediatorID: @mediator.UserID)
    @case.update!(TenantSideConversationID: @side.ConversationID)
  end

  def build_security_document(conversation_id: @case.ConversationID)
    file = FileDraft.create!(CreatorID: @landlord.UserID, FileName: "Security test",
      FileTypes: "html", FileURLPath: "security-test.html")
    message = Message.create!(ConversationID: conversation_id, SenderID: @landlord.UserID,
      Contents: "Document", MessageDate: Time.current)
    FileAttachment.create!(FileID: file.FileID, MessageID: message.MessageID)
    file
  end

  def build_document_role_overlap(role)
    if role == "Primary"
      SideMessageGroup.where(ConversationID: @case.ConversationID).update_all(
        UserID: @outsider.UserID, MediatorID: @other_mediator.UserID)
      build_security_document
    else
      PrimaryMessageGroup.create!(ConversationID: @side.ConversationID,
        TenantID: @outsider.UserID, LandlordID: users(:landlord2).UserID,
        MediatorID: @other_mediator.UserID)
      build_security_document(conversation_id: @side.ConversationID)
    end
  end
end
