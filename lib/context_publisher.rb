# frozen_string_literal: true

require_relative "context_event_handler"

# The name the other ABsmartly SDKs use for ContextEventHandler. Defined only
# if the application has no constant of that name, so the SDK never replaces
# or clashes with one.
ContextPublisher = ContextEventHandler unless Object.const_defined?(:ContextPublisher, false)
