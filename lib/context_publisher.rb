# frozen_string_literal: true

require_relative "context_event_handler"

module Absmartly
  # The name the other ABsmartly SDKs use for ContextEventHandler. Namespaced
  # so it can't clash with an application's own ContextPublisher.
  ContextPublisher = ::ContextEventHandler
end
