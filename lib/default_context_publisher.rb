# frozen_string_literal: true

require_relative "context_publisher"
require_relative "default_context_event_handler"

# The name the other ABsmartly SDKs use for DefaultContextEventHandler. Defined
# only if the application has no constant of that name.
DefaultContextPublisher = DefaultContextEventHandler unless Object.const_defined?(:DefaultContextPublisher, false)
