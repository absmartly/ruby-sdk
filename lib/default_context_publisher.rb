# frozen_string_literal: true

require_relative "context_publisher"
require_relative "default_context_event_handler"

module Absmartly
  # The name the other ABsmartly SDKs use for DefaultContextEventHandler.
  DefaultContextPublisher = ::DefaultContextEventHandler
end
