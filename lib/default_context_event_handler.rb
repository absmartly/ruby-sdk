# frozen_string_literal: true

require_relative "context_event_handler"

class DefaultContextEventHandler < ContextDataProvider
  attr_accessor :client

  def initialize(client)
    @client = client
  end

  def publish(context, event)
    @client.publish(event)
  end
end
